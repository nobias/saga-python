#!/bin/sh

# this script uses only POSIX shell functionality, and does not rely on bash or
# other shell extensions.  It expects /bin/sh to be a POSIX compliant shell
# thought.


# --------------------------------------------------------------------
#
# ERROR and RETVAL are used for return state from function calls
#
ERROR=""
RETVAL=""

# this is where this 'daemon' keeps state for all started jobs
BASE=$HOME/.saga/adaptors/ssh_job/


# --------------------------------------------------------------------
#
# utility call which extracts the first argument and returns it.
#
get_cmd () {
  if test -z $1 ; then ERROR="no command given"; return; 
  else                 RETVAL=$1;                fi
}


# --------------------------------------------------------------------
#
# utility call which strips the first of a set of arguments, and returns the
# remaining ones in a space separated string
#
get_args () {
  if test -z $1 ; then ERROR="no command given"; return; 
  else                 shift; RETVAL=$@;         fi 
}


# --------------------------------------------------------------------
#
# utility call which ensures that a given job id points to a viable working
# directory
#
verify_pid () {
  if test -z $1 ;            then ERROR="no pid given";              return 1; fi 
  DIR="$BASE/$1"
  if ! test -d "$DIR";       then ERROR="pid $1 not known";          return 1; fi 
  if ! test -r "$DIR/pid";   then ERROR="pid $1 in incorrect state"; return 1; fi 
  if ! test -r "$DIR/state"; then ERROR="pid $1 in incorrect state"; return 1; fi
}


# --------------------------------------------------------------------
#
# run a job in the background.  Note that the returned job ID is actually the
# pid of the shell process which wraps the actual job, monitors its state, and
# serves its I/O channels.  The actual job id is stored in the 'pid' file in the
# jobs working directory.
#
# Note that the actual job is not run directly, but via nohup.  Otherwise all
# jobs would be canceled as soon as this master script finishes...
#
# Note that the working directory is created on the fly.  As the name of the dir
# is the pid, it must be unique -- we thus purge whatever trace we find of an
# earlier directory of the same name.
#
# Known limitations:
#
# The script has a small race condition, between starting the job (the 'nohup'
# line), and the next line where the jobs now know pid is stored away.  I don't
# see an option to make those two ops atomic, or resilient against script
# failure - so, in worst case, you might get a running job for which the job id
# is not stored (i.e. not known).  
#
# Also, the line after is when the job state is set to 'Running' -- we can't
# really do that before, but on failure, in the worst case, we might have a job
# with known job ID which is not marked as running.  
#
# Finally, the wait call must be in this shell instance -- if this instance dies
# we will not be able to recover the exit state of the job.  We will, however,
# be able to recover its SAGA state...
#
# FIXME?

cmd_run () {
  cmd_run_process $@ &
  RETVAL=$!
  wait $RETVAL
}

cmd_run_process () {
  PID=`sh -c 'echo $PPID'`
  DIR="$BASE/$PID"

  rm    -rf "$DIR"
  mkdir -p  "$DIR"  || exit 1
  echo "NEW"         > "$DIR/state"
  echo "$@"          > "$DIR/cmd"
  touch                "$DIR/in"

  # create a script which represents the job.  The 'exec' call will replace the
  # script's shell instance with the job executable, leaving the I/O
  # redirections intact.
  cat                > "$DIR/job.sh" <<EOT
  exec $@            \
    <  "$DIR/in"     \
    >  "$DIR/out"    \
    2> "$DIR/err"
EOT
  
  # the job script above is started by this startup script, which makes sure
  # that the job state is properly watched and captured.
  cat                > "$DIR/monitor.sh" <<EOT
    DIR=$DIR
    nohup /bin/sh      "\$DIR/job.sh" 1>/dev/null 2>/dev/null 3</dev/null &
    rpid=\$!
    echo \$rpid      > "\$DIR/pid"
    echo "RUNNING"   > "\$DIR/state"

    while true
    do
      wait \$rpid
      retv=\$?

      # if wait failed for other reason than job finishing, i.e. due to
      # suspend/resume, then we need to wait again, otherwise we are done
      # waiting...
      if test -e "\$DIR/suspended"; then
        # need to wait again
        sleep 1
      else
        # evaluate exit val
        echo \$retv > "\$DIR/exit"
        test \$retv = 0           && echo DONE      > "\$DIR/state"
        test \$retv = 0           || echo FAILED    > "\$DIR/state"

        # capture canceled state
        test -e "\$DIR/canceled"  && echo CANCELED  > "\$DIR/state"
        test -e "\$DIR/canceled"  && rm -f            "\$DIR/canceled"

        # done waiting
        break
      fi
    done

EOT

  # the monitor script is ran asynchronously and with nohup, so that its
  # lifetime will not be bound to the manager script lifetime.
  nohup /bin/sh "$DIR/monitor.sh" 1>/dev/null 2>/dev/null 3</dev/null &
  exit
}


# --------------------------------------------------------------------
#
# inspect job state
#
cmd_state () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  RETVAL=`cat "$DIR/state"`
}


# --------------------------------------------------------------------
#
# suspend a running job
#
cmd_suspend () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  state=`cat "$DIR/state"`
  rpid=`cat "$DIR/pid"`

  if ! test "$state" = "RUNNING"; then
    ERROR="job $1 in incorrect state ($state != RUNNING)"
    return
  fi

  touch "$DIR/suspended"
  RETVAL=`kill -STOP $rpid 2>&1`
  ECODE=$?

  if test "$ECODE" = "0" ; then
    mv    "$DIR/state" "$DIR/state.susp"
    echo SUSPENDED >   "$DIR/state"
    RETVAL="$1 suspended"
  else
    ERROR="suspend failed ($ECODE): $RETVAL"
  fi

}


# --------------------------------------------------------------------
#
# resume a suspended job
#
cmd_resume () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  state=`cat $DIR/state`
  rpid=`cat $DIR/pid`

  if ! test "$state" = "SUSPENDED"; then
    ERROR="job $1 in incorrect state ($state != SUSPENDED)"
    return
  fi

  RETVAL=`kill -CONT $rpid 2>&1`
  ECODE=$?

  if test "$ECODE" = "0" ; then
    mv    "$DIR/state.susp" "$DIR/state"
    rm -f "$DIR/suspended"
    RETVAL="$1 resumed"
  else
    ERROR="resume failed ($ECODE): $RETVAL"
  fi

}


# --------------------------------------------------------------------
#
# kill a job, and set state to canceled
#
cmd_cancel () {
  verify_pid $1 || return

  DIR="$BASE/$1"

  state=`cat $DIR/state`
  rpid=`cat $DIR/pid`

  if test "$state" != "SUSPENDED" -a "$state" != "RUNNING"; then
    ERROR="job $1 in incorrect state ('$state' != 'SUSPENDED|RUNNING')"
    return
  fi

  touch "$DIR/canceled"
  RETVAL=`kill -KILL $rpid 2>&1`
  ECODE=$?

  if test "$ECODE" = "0" ; then
    RETVAL="$1 canceled"
  else
    # kill failed!
    rm -f "$DIR/canceled"
    ERROR="cancel failed ($ECODE): $RETVAL"
  fi
}


# --------------------------------------------------------------------
#
# feed given string to job's stdin stream
# 
cmd_stdin () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  shift
  echo "$*" >> "$DIR/in"
  RETVAL="stdin refreshed"
}


# --------------------------------------------------------------------
#
# print uuencoded string of job's stdout
#
cmd_stdout () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  RETVAL=`uuencode "$DIR/out" "/dev/stdout"`
}


# --------------------------------------------------------------------
#
# print uuencoded string of job's stderr
#
cmd_stderr () {
  verify_pid $1 || return

  DIR="$BASE/$1"
  RETVAL=`uuencode "$DIR/err" "/dev/stdout"`
}


# --------------------------------------------------------------------
#
# list all job IDs
#
cmd_list () {
  for d in "$BASE"/*; do
    RETVAL="$RETVAL`basename $d` "
  done

  if test "$RETVAL" = "* "; then RETVAL=""; fi
}


# --------------------------------------------------------------------
#
# purge working directories of given jobs (all non-final jobs as default)
#
cmd_purge () {

  if test -z "$1" ; then
    for d in `grep -l -e 'DONE' -e 'FAILED' -e 'CANCELED' "$BASE"/*/state`; do
      dir=`dirname $d`
      id=`basename $dir`
      rm -rf "$BASE/$id"
    done
    RETVAL="purged finished jobs"
    return
  fi

  verify_pid $1 || return

  DIR="$BASE/$1"
  rm -rf "$DIR"
  RETVAL="purged $1"
}


cmd_run /bin/sleep 100
echo $RETVAL
ps -ef --forest | grep -C 4 $RETVAL

cmd_run /bin/sleep 100
echo $RETVAL
ps -ef --forest | grep -C 4 $RETVAL

cmd_run /bin/sleep 1
echo $RETVAL
ps -ef --forest | grep -C 4 $RETVAL

cmd_run /bin/sleep 1
echo $RETVAL
ps -ef --forest | grep -C 4 $RETVAL


sleep 1000

