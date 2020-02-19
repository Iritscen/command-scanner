#!/bin/bash

# CommandScanner
# Pass this script another Bash script to find out what commands it uses which are not built into the
# command line. There are a few known shortcomings with the parsing heuristics:
# - This script ignores the contents of strings when searching for command names, so if you are running
# 'eval' on any strings in your script, the commands contained in the 'eval'ed strings will be missed,
# requiring manual review.
# - A string containing a binary path which is used to invoke a command will fail to be recognized, and
# any arguments passed to that binary without leading hyphens will be treated as commands.
# - If a variable is never officially declared with a "VAR=" statement, or a function is not declared
# with the keyword "function", the variable/function will be treated as a command name.
# - Various other assumptions were made, intentionally or not, based on my own coding style and what
# would produce the right results for my own Bash scripts.
# Recommended width:
# |---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- -----|

# Bash reserved words. Source: This is a selected list of reserved words I supplied myself. "compgen -k"
# and even "man builtin" do not supply all reserved words, plus "man builtin" supplies many words that
# are never used in my scripts, so to keep the script's execution time down I have only included what is
# needed to validate my own scripts. Relevant env. variables such as $HOME get added here as well.
declare -a BASH_KEYWORDS=(for in do done if then elif else fi while until continue break let case shift esac select declare unset eval function time trap return exit EOF HOME INT TZ)

# POSIX Standard commands. Source: https://pubs.opengroup.org/onlinepubs/9699919799/idx/utilities.html
declare -a POSIX_STANDARD=(admin alias ar asa at awk basename batch bc bg c99 cal cat cd cflow chgrp chmod chown cksum cmp comm command compress cp crontab csplit ctags cut cxref date dd delta df diff dirname du echo ed env ex expand expr false fc fg file find fold fort77 fuser gencat get getconf getopts grep hash head iconv id ipcrm ipcs jobs join kill lex link ln locale localedef logger logname lp ls m4 mailx make man mesg mkdir mkfifo more mv newgrp nice nl nm nohup od paste patch pathchk pax pr printf prs ps pwd qalter qdel qhold qmove qmsg qrerun qrls qselect qsig qstat qsub read renice rm rmdel rmdir sact sccs sed sh sleep sort split strings strip stty tabs tail talk tee test time touch tput tr true tsort tty type ulimit umask unalias uname uncompress unexpand unget uniq unlink uucp uudecode uuencode uustat uux val vi wait wc what who write xargs yacc zcat)

# GNU Standard commands. Source: https://unix.stackexchange.com/a/37088/241464
declare -a GNU_STANDARD=(find xargs grep egrep bash gzip sed tar)

# macOS commands. Source: Me. Any command that I use in my scripts that came built-in on the macOS
# command line but which does not appear in the GNU and POSIX standards is placed here.
declare -a MAC_COMMANDS=(clear codesign col curl diskutil exec expect fmt hdiutil less md5 mktemp mount newfs_hfs open opendiff osascript perl seq shopt sqlite3 stat sudo which xcodebuild xsltproc zip)

# Make sure script exists
if [ ! -f "$1" ]; then
   echo "Could not find a script at path '$1'."
fi

# Save script's line count
NUM_LINES=$(wc -l "$1")
NUM_LINES=$(echo $NUM_LINES | egrep -o "[[:digit:]]* ")
NUM_LINES=$(echo $NUM_LINES | tr -d '[:space:]')

# Load file into memory and prepare some variables
IFS="
"
SCRIPT_TEXT_RAW=$(cat "$1")
declare -a SCRIPT_TEXT_TERMS=()
declare -a SCRIPT_TEXT_SORTED=()
bold=$(tput bold)
norm=$(tput sgr0)

# Find the script's variable and function names and save them in arrays
echo "Prescanning script for variables and functions..."
declare -a VARS_AND_FUNCS=()
CUR_LINE=1
for THE_LINE in `cat "$1"`; do
   # Look for some number of char.s that could be a var. name, followed by a '='
   var_declare=$(echo "$THE_LINE" | egrep -o "^[[:space:]]*[a-zA-Z0-9_]+=" | cut -d '=' -f 1 | tr -d '[:space:]')
   if [ ! -z "$var_declare" ]; then
      VARS_AND_FUNCS+=("$var_declare")
      #echo "Picked up variable declaration '$var_declare' on line $CUR_LINE."
   fi

   # Look for an array declaration
   arr_declare=$(echo "$THE_LINE" | egrep "^[[:space:]]*declare" | egrep -o "[a-zA-Z0-9_]+=" | cut -d '=' -f 1 | tr -d '[:space:]')
   if [ ! -z "$arr_declare" ]; then
      VARS_AND_FUNCS+=("$arr_declare")
      #echo "Picked up array declaration '$arr_declare' on line $CUR_LINE."
   fi

   # Look for a 'for' loop variable, and filter out lines that are comments or strings
   var_for=$(echo "$THE_LINE" | egrep "for [a-zA-Z0-9_]+" | egrep -v "[#\"].*for" | egrep -o "for [a-zA-Z0-9_]+"  | sed 's/for //')
   if [ ! -z "$var_for" ]; then
      VARS_AND_FUNCS+=("$var_for")
      #echo "Picked up 'for' loop variable '$var_for' on line $CUR_LINE."
   fi

   # Look for a function declared with "function ___"
   func_declare=$(echo "$THE_LINE" | egrep -o "function [a-zA-Z0-9_]+" | sed 's/function //')
   if [ ! -z "$func_declare" ]; then
      VARS_AND_FUNCS+=("$func_declare")
      #echo "Picked up function declaration '$func_declare' on line $CUR_LINE."
   fi

   let CUR_LINE+=1
done
CUR_LINE=0

# Get the size of the script we are parsing
IFS=" "
declare -a FILE_INFO=(`ls -al "$1"`)
NUM_CHARS=${FILE_INFO[4]}
if [ $NUM_CHARS -lt 1 ] || [ $NUM_CHARS -gt 50000 ]; then
   echo "Got a character count of '$NUM_CHARS' for this script, is that right? Exiting."
   exit
fi

# Print debugging messages for this line range
DEBUG_START=0
DEBUG_END=0

# Print a debugging message only if we're within the specified range of lines
function dbg()
{
   if [ $CUR_LINE -ge $DEBUG_START ] && [ $CUR_LINE -le $DEBUG_END ]; then
      echo $1
   fi
}

# Set up variables for our main loop
IN_COMMENT=0
IN_SINGLE_QUOTE=0
IN_DOUBLE_QUOTE=0
IN_CASE=0
PAST_PARENS=0
IN_EOF=0
EOF_STARTED=0
LAST_SCANNED=0
IN_TERM=0
POSSIBLE_CMD=1
POST_SUPER=0
CUR_LINE=1
CUR_COL=1
CUR_CHAR=""
LINE_START=1
LAST_TERM=""
PREV_CHAR=""
PREV_PREV_CHAR=""
PREV_PREV_PREV_CHAR=""
PRESCANNED=0
FIRST_TERM=0
HAS_PARENS=0
# Optional limiters for debugging purposes
#CHAR_LIMIT=1000
#LINE_LIMIT=100
#LINE_MIN=900
#LINE_MAX=950

# Run through SCRIPT_TEXT_RAW one character at a time, ignoring comments, strings and EOF blocks
# (that's where you use "EOF" to mark the end of a stream of data), and copy the remaining words to
# SCRIPT_TEXT_TERMS
echo "Parsing script for terms..."
if [ $DEBUG_START -eq 0 ] && [ $DEBUG_END -eq 0 ]; then
   echo -n "1/$NUM_LINES lines processed..."
fi
IFS=""
for ((i = 0; i < $NUM_CHARS; ++i)); do
   PREV_PREV_PREV_CHAR="$PREV_PREV_CHAR"
   PREV_PREV_CHAR="$PREV_CHAR"
   PREV_CHAR="$CUR_CHAR"
   CUR_CHAR="${SCRIPT_TEXT_RAW:$i:1}"
   CUR_COL=$(($i-$LINE_START))
   dbg "Evaluating $CUR_CHAR"

   # Adjust these variables if we hit a newline
   if [ "$CUR_CHAR" == "
" ]; then
      let CUR_LINE+=1
      if [ $DEBUG_START -eq 0 ] && [ $DEBUG_END -eq 0 ]; then
         printf "\e[1A\n"
         echo -n "$(($CUR_LINE-1))/$NUM_LINES lines processed..."
      fi
      dbg "Now on line $CUR_LINE"
      PREV_CHAR=""
      PREV_PREV_CHAR=""
      PREV_PREV_PREV_CHAR=""
      IN_COMMENT=0
      POST_SUPER=0
      PAST_PARENS=0
      LINE_START=$i
      HAS_PARENS=0
      PRESCANNED=0
      FIRST_TERM=1
   fi

   # Don't look at this line if it's outside of the requested range
   if [ ! -z "$LINE_MIN" ] && [ $CUR_LINE -lt "$LINE_MIN" ]; then
      continue
   fi
   if [ ! -z "$LINE_MAX" ] && [ $CUR_LINE -gt "$LINE_MAX" ]; then
      continue
   fi

   # Look for start or end of an EOF block
   if [ $EOF_STARTED -lt $CUR_LINE ] && [ $LAST_SCANNED -lt $CUR_LINE ]; then
      LAST_SCANNED=$CUR_LINE
      # Perform a rare lookahead to the entire line
      FULL_LINE=$(tail -n+$CUR_LINE "$1" | head -n1)
      if [ $IN_EOF -eq 0 ]; then
         # Assume that the start of an EOF block is marked by the here-document operator
         RESULT=$(echo "$FULL_LINE" | egrep "<<.*EOF" | egrep -v "egrep")
         RESULT_CHARS=`echo -n "$RESULT" | wc -c`
         if [ "$RESULT_CHARS" -ge 2 ]; then
            dbg "Found start of EOF block on line $CUR_LINE."
            IN_EOF=1
            continue
         fi
      else
         # Assume that the EOF block ends with "EOF" at the very beginning of a line
         RESULT=`echo "$FULL_LINE" | egrep "^EOF"`
         RESULT_CHARS=`echo -n "$RESULT" | wc -c`
         if [ "$RESULT_CHARS" -ge 2 ]; then
            dbg "Found end of EOF block on line $CUR_LINE."
            IN_EOF=0
         fi
      fi
   fi

   # Don't pass this point while we're in an EOF block
   if [ $IN_EOF -eq 1 ]; then
      continue
   fi

   # If the '#' isn't being used to get the number of arguments ("$#") or the number of elements in an
   # array ("{#ARRAY[@]}"), and we're not inside a string, then we consider it a comment
   if [ "$CUR_CHAR" == "#" ] && [ "$PREV_CHAR" != "$" ] && [ "$PREV_CHAR" != "{" ] && [ $IN_SINGLE_QUOTE -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_EOF -eq 0 ]; then
      dbg "Entered comment on line $CUR_LINE."
      IN_COMMENT=1
   fi

   # If we hit a single-quote character...
   if [ "$CUR_CHAR" == "'" ]; then
      # ...and it wasn't escaped (or else the escape was escaped)...
      if [ "$PREV_CHAR" != "\\" ] || ([ "$PREV_CHAR" == "\\" ] && [ "$PREV_PREV_CHAR" == "\\" ]); then
         # ...and we're not already in a string or comment...
         if [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_COMMENT -eq 0 ]; then
            # ...then a string has started or ended, so flip our boolean
            IN_SINGLE_QUOTE=$((IN_SINGLE_QUOTE ^= 1))
            dbg "IN_SINGLE_QUOTE changed to $IN_SINGLE_QUOTE on line $CUR_LINE col $CUR_COL."
         fi
      fi
   # Same for a double-quote character
   elif [ "$CUR_CHAR" == "\"" ]; then
      if [ "$PREV_CHAR" != "\\" ] || ([ "$PREV_CHAR" == "\\" ] && [ "$PREV_PREV_CHAR" == "\\" ]); then
         if [ $IN_SINGLE_QUOTE -eq 0 ] && [ $IN_COMMENT -eq 0 ]; then
            IN_DOUBLE_QUOTE=$((IN_DOUBLE_QUOTE ^= 1))
            dbg "IN_DOUBLE_QUOTE changed to $IN_DOUBLE_QUOTE on line $CUR_LINE col $CUR_COL. PREV_CHAR was '$PREV_CHAR'."
         fi
      fi
   fi

   # Look for signs of a possible command:
   if [ $IN_COMMENT -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_SINGLE_QUOTE -eq 0 ]; then
      # - If we're following a space character or we're at the beginning of the line...
      if [[ "$PREV_CHAR" =~ [[:space:]] ]] || [ "$PREV_CHAR" == "" ]; then
         # ...and it's the first term we've found on this line and this is a letter
         if [ $FIRST_TERM -eq 1 ] && [[ "$CUR_CHAR" =~ [[:alpha:]] ]]; then
            dbg "Marked possible command due to being first term on line $CUR_LINE (col is $CUR_COL)."
            POSSIBLE_CMD=1
         fi
      fi
      # - If we're following " | ", then this might be a command receiving another command's output
      if [ "$PREV_PREV_PREV_CHAR" == " " ] && [ "$PREV_PREV_CHAR" == "|" ] && [ "$PREV_CHAR" == " " ]; then
         dbg "Marked possible command after ' | ' on line $CUR_LINE."
         POSSIBLE_CMD=1
      # - If we're following a semicolon, then this could be a second command on the same line
      elif [ "$PREV_CHAR" == ";" ]; then
         dbg "Marked possible command after ';' on line $CUR_LINE."
         POSSIBLE_CMD=1
      # - If we're following "$(" or "`", there's a good chance this is a command
      elif ([ "$PREV_PREV_CHAR" == "$" ] && [ "$PREV_CHAR" == "(" ]) || [ "$PREV_CHAR" == "\`" ]; then
         dbg "Marked possible command after '\$(' on line $CUR_LINE."
         POSSIBLE_CMD=1
      fi
   fi

   # If we're in a "case" block and haven't gotten to the ')' yet, we're looking at a case argument, so
   # set a flag to not count this as a term
   if [ $IN_COMMENT -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_SINGLE_QUOTE -eq 0 ]; then
      if [ $IN_CASE -eq 1 ]; then
         # Perform a rare lookahead to the entire line
         if [ $PRESCANNED -eq 0 ]; then
            # If there's a ')' on the line, then we're starting in an argument, which is a term that we
            # want to ignore, so set the flag HAS_PARENS to make sure we skip past the parens before
            # we start looking at terms
            FULL_LINE=$(tail -n+$CUR_LINE "$1" | head -n1)
            RESULT=`echo "$FULL_LINE" | grep ")"`
            RESULT_CHARS=`echo -n "$RESULT" | wc -c`
            if [ "$RESULT_CHARS" -ge 2 ]; then
               HAS_PARENS=1
            else
               HAS_PARENS=0
            fi
            PRESCANNED=1
         fi
         # Make an exception for a line that has no argument on it, which allows us to catch "esac"
         if [ "$CUR_CHAR" == ")" ] || [ $HAS_PARENS -eq 0 ]; then
            dbg "PAST_PARENS is now 1 on line $CUR_LINE."
            PAST_PARENS=1
         fi
      fi
   fi

   # Mark a term to be saved if it's not in a comment or string...
   if [ $IN_COMMENT -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_SINGLE_QUOTE -eq 0 ]; then
      # ...as long as this term starts with a letter...
      if [ $IN_TERM -eq 0 ] && [[ "$CUR_CHAR" =~ [[:alpha:]] ]]; then
         # ...and it has been flagged as a possible command or immediately follows a super-command...
         if [ $POSSIBLE_CMD -eq 1 ] || [ $POST_SUPER -eq 1 ]; then
            # ...and the previous character does not disqualify this as the start of a Bash command...
            if [[ ! "$PREV_CHAR" =~ [a-zA-Z[0-9=/}:._-] ]]; then
               # ...and as long as we're not in a "case" block and currently looking at a case argument
               if (! ([ $IN_CASE -eq 1 ] && [ $PAST_PARENS -eq 0 ])); then
                  IN_TERM=1
                  dbg "IN_TERM was set to 1 on line $CUR_LINE col $CUR_COL."
               fi
            fi
         fi
      # Recognize if we have reached the end of the term
      elif [ $IN_TERM -eq 1 ] && [[ ! "$CUR_CHAR" =~ [a-zA-Z0-9_] ]]; then
         IN_TERM=0
      fi
   fi

   # Keep adding the latest character to the term we're building if we're still in it...
   if [ $IN_TERM -eq 1 ]; then
      FIRST_TERM=0
      LAST_TERM+="$CUR_CHAR"
   # ...otherwise, if we're done iterating over a term, add it to SCRIPT_TEXT_TERMS if it's more than
   # one character
   elif [ $IN_TERM -eq 0 ] && [ ! -z "$LAST_TERM" ]; then
      dbg "Found term '$LAST_TERM' on line $CUR_LINE."
      if [ ${#LAST_TERM} -gt 1 ]; then
         SCRIPT_TEXT_TERMS+=("$LAST_TERM")

         # If this is a term that we recognize as a super-command (it presides over a subsequent
         # command), set a flag
         if [ "$LAST_TERM" == "sudo" ] || [ "$LAST_TERM" == "time" ]; then
            dbg "POST_SUPER is now 1 on line $CUR_LINE."
            POST_SUPER=1
         else
            POST_SUPER=0
         fi

         # If we've entered a "case" statement, set a flag
         if [ "$LAST_TERM" == "case" ]; then
            dbg "Entering 'case' statement on line $CUR_LINE."
            IN_CASE=1
         elif [ "$LAST_TERM" == "esac" ]; then
            dbg "Exiting 'case' statement on line $CUR_LINE."
            IN_CASE=0
         fi
      fi

      # Reset relevant variables
      POSSIBLE_CMD=0
      LAST_TERM=""
      if [ $i -ne $LINE_START ]; then
         FIRST_TERM=0
      fi
   fi

   # Stop at character/line limit if one is set
   if [ ! -z "$CHAR_LIMIT" ] && [ $i -gt "$CHAR_LIMIT" ]; then
      break
   fi
   if [ ! -z "$LINE_LIMIT" ] && [ $CUR_LINE -gt "$LINE_LIMIT" ]; then
      break
   fi
done
echo

# Save last term that was captured by the loop
if [ ! -z "$LAST_TERM" ]; then
   SCRIPT_TEXT_TERMS+=("$LAST_TERM")
fi
if [ ${#SCRIPT_TEXT_TERMS[@]} -lt 1 ]; then
   echo "Found no terms to evaluate!"
   exit
fi

# 'sort' and 'uniq' SCRIPT_TEXT_TERMS into SCRIPT_TEXT_SORTED for faster checking against the
# various arrays we're going to bring into play next
IFS="
"
SCRIPT_TEXT_SORTED=($(sort -f <<< "${SCRIPT_TEXT_TERMS[*]}"))
SCRIPT_TEXT_SORTED=($(uniq <<< "${SCRIPT_TEXT_SORTED[*]}"))

# Filter terms through one array of keywords/commands at a time, stopping if there are no terms left
declare -a ARRAY_TO_FILTER=("${SCRIPT_TEXT_SORTED[@]}")
declare -a FILTER_ARRAY=()
FILTER_NAME=""
for ((a = 0; a < 5; ++a)); do
   STR_TERMS="terms"
   if [ ${#ARRAY_TO_FILTER[*]} -eq 1 ]; then
      STR_TERMS="term"
   fi

   unset SCRIPT_TEXT_REMAINDER
   declare -a SCRIPT_TEXT_REMAINDER=()
   echo "${#ARRAY_TO_FILTER[*]} $STR_TERMS left to filter: ${ARRAY_TO_FILTER[@]}." | fmt -w 80
   case $a in
      0 ) FILTER_ARRAY=(${VARS_AND_FUNCS[@]}); FILTER_NAME="functions and variables";;
      1 ) FILTER_ARRAY=(${BASH_KEYWORDS[@]}); FILTER_NAME="Bash reserved words";;
      2 ) FILTER_ARRAY=(${POSIX_STANDARD[@]}); FILTER_NAME="POSIX commands";;
      3 ) FILTER_ARRAY=(${GNU_STANDARD[@]}); FILTER_NAME="GNU standard commands";;
      4 ) FILTER_ARRAY=(${MAC_COMMANDS[@]}); FILTER_NAME="macOS extended commands";;
      * ) echo "Shouldn't have gotten here! Exiting."; exit;;
   esac
   echo "Now filtering against $FILTER_NAME."
   for ((i = 0; i < ${#ARRAY_TO_FILTER[@]}; ++i)); do
      MATCH=0
      for THE_VAR in ${FILTER_ARRAY[@]}; do
         if [ "$THE_VAR" == "${ARRAY_TO_FILTER[$i]}" ]; then
            MATCH=1
            break
         fi
      done
      if [ $MATCH -ne 1 ]; then
         SCRIPT_TEXT_REMAINDER+=("${ARRAY_TO_FILTER[$i]}")
      fi
   done
   if [ ${#SCRIPT_TEXT_REMAINDER[@]} -lt 1 ]; then
      echo "No terms left to evaluate after removing $FILTER_NAME."
      break
   else
      unset ARRAY_TO_FILTER
      declare -a ARRAY_TO_FILTER=(${SCRIPT_TEXT_REMAINDER[@]})
   fi
done

# Inform the user of our findings
if [ ${#SCRIPT_TEXT_REMAINDER[@]} -gt 0 ]; then
   if [ ${#SCRIPT_TEXT_REMAINDER[@]} -eq 1 ]; then
   echo -e "${bold}The following command appears to be a third-party program not built into the macOS Bash shell: " | fold -s
   echo -e "${SCRIPT_TEXT_REMAINDER[0]}${norm}"
   else
      echo -e "${bold}The following ${#SCRIPT_TEXT_REMAINDER[@]} commands appear to be third-party programs not built into the macOS Bash shell:" | fold -s
      for ((i = 0; i < ${#SCRIPT_TEXT_REMAINDER[@]}; ++i)); do
         echo "${SCRIPT_TEXT_REMAINDER[$i]}"
      done
      echo -ne "${norm}"
   fi
else
   echo -e "All the commands used in this script are built into the macOS Bash shell." | fmt -w 80
fi