#!/bin/bash

# CommandScanner
# Pass this script another shell script to find out what commands it uses which are not built into the
# command line. There are extensive limitations due to the simple parsing heuristics:
# - This script ignores the contents of strings, which normally makes sense when validating every word
# against a list of commands, but if you are running 'eval' on any strings in your script, the commands
# contained in the 'eval'ed strings will be missed, requiring manual review.
# - If a command invocation contains an argument not immediately preceded by a '-', e.g. "ffprobe -v
# quiet", that argument will be erroneously treated as a command.
# - An array declaration such as "declare -a ARRAY=(one two)" will cause "one" and "two" to be treated
# as commands.
# - Patterns under 'case' statements are treated as commands, e.g. "arg1" in "case '$1' in arg1 )".
# - The script knows that "EOF" is a commonly-used term but does not understand that unquoted text that
# follows it, e.g. "cat << EOF [some text] EOF" is a string.
# - 'for' statements that use sequences, e.g. "for MY_WORD in word1 word2 word3" will have the sequence
# elements treated as commands.
# - A string comparison without quotes, e.g. "if [ $TEXT == something ]" will treat "something" as a
# command.
# - If a variable is never officially declared with a "VAR=" statement, it will be treated as a command.
# - If the character sequence \\" or \\' occurs in the script, it will be treated as an escaped quote
# mark, when really it's an escaped backslash followed by the end of a string. This will cause every
# string afterwards to be read as a non-string and vice versa, disrupting the parsing of the script.
# Recommended width:
# |---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- -----|

# Bash reserved words. Source: This is a selected list of reserved words I supplied myself. "compgen -k"
# and even "man builtin" do not supply all reserved words, plus "man builtin" supplies many words that
# are never used in my scripts, so to keep the script's execution time down I have only included what is
# needed to validate my own scripts. Relevant env. variables have been added in as well.
declare -a BASH_KEYWORDS=(for in do done if then elif else fi while until continue break let case shift esac select declare unset eval function time trap return exit EOF HOME INT)

# POSIX Standard commands. Source: https://pubs.opengroup.org/onlinepubs/9699919799/idx/utilities.html
declare -a POSIX_STANDARD=(admin alias ar asa at awk basename batch bc bg c99 cal cat cd cflow chgrp chmod chown cksum cmp comm command compress cp crontab csplit ctags cut cxref date dd delta df diff dirname du echo ed env ex expand expr false fc fg file find fold fort77 fuser gencat get getconf getopts grep hash head iconv id ipcrm ipcs jobs join kill lex link ln locale localedef logger logname lp ls m4 mailx make man mesg mkdir mkfifo more mv newgrp nice nl nm nohup od paste patch pathchk pax pr printf prs ps pwd qalter qdel qhold qmove qmsg qrerun qrls qselect qsig qstat qsub read renice rm rmdel rmdir sact sccs sed sh sleep sort split strings strip stty tabs tail talk tee test time touch tput tr true tsort tty type ulimit umask unalias uname uncompress unexpand unget uniq unlink uucp uudecode uuencode uustat uux val vi wait wc what who write xargs yacc zcat)

# GNU Standard commands. Source: https://unix.stackexchange.com/a/37088/241464
declare -a GNU_STANDARD=(find xargs grep egrep bash gzip sed tar)

# macOS commands. Source: Me. Any command that I use in my scripts that came built-in on the macOS
# command line but which does not appear in the GNU and POSIX standards is placed here.
declare -a MAC_COMMANDS=(clear codesign col curl diskutil exec expect fmt hdiutil less md5 mktemp mount open opendiff osascript perl seq shopt sqlite3 sudo which xcodebuild xsltproc zip)

# Load file into memory and prepare variables for processing
IFS="
"
SCRIPT_TEXT_RAW=$(cat "$1")
declare -a SCRIPT_TEXT_TERMS=()
declare -a SCRIPT_TEXT_SORTED=()

# Find variables and save them in array. Variables are defined as the words found before a '=' or after
# a "for".
echo "Prescanning script for variables and functions..."
declare -a VARS_AND_FUNCS=()
for THE_LINE in `cat "$1"`; do
   VARS_AND_FUNCS+=($(echo "$THE_LINE" | egrep -o "[a-zA-Z0-9_]+=" | cut -d '=' -f 1))
   VARS_AND_FUNCS+=($(echo "$THE_LINE" | egrep -o "for [a-zA-Z0-9_]+" | sed 's/for //'))
   VARS_AND_FUNCS+=($(echo "$THE_LINE" | egrep -o "function [a-zA-Z0-9_]+" | sed 's/function //'))
done

# Get size of script we are parsing
IFS=" "
declare -a FILE_INFO=(`ls -al "$1"`)
NUM_CHARS=${FILE_INFO[4]}
if [ $NUM_CHARS -lt 1 ] || [ $NUM_CHARS -gt 50000 ]; then
   echo "Got character count of '$NUM_CHARS' for this script, is that right? Exiting."
   exit
fi

# Run through SCRIPT_TEXT_RAW one character at a time, ignoring comments, strings and variables, and
# copying the remaining words to SCRIPT_TEXT_TERMS
echo "Parsing script for terms..."
IFS=""
IN_COMMENT=0
IN_SINGLE_QUOTE=0
IN_DOUBLE_QUOTE=0
IN_TERM=0 # 0 = not in term, 1 = in variable/keyword/command, 2 = other
CUR_LINE=1
CUR_CHAR=1
LAST_TERM=""
LAST_CHAR="#"
#NUM_CHARS=1000
for ((i = 0; i < $NUM_CHARS; ++i, CUR_CHAR++)); do
   THE_CHAR="${SCRIPT_TEXT_RAW:$i:1}"
   #echo "Evaluating $THE_CHAR"

   # If we're not in a comment or string...
   if [ $IN_COMMENT -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_SINGLE_QUOTE -eq 0 ]; then
      # ...and this is the beginning of a term...
      if [ $IN_TERM -eq 0 ] && [[ "$THE_CHAR" =~ [[:alpha:]] ]]; then
         # ...and it's not following certain punctuation that marks it as an argument, e.g. "-name",
         # "640x480"...
         if [[ "$LAST_CHAR" =~ [0-9=/}:.[-] ]]; then
            IN_TERM=2
         # ...then we're in a term
         else
            IN_TERM=1
         fi
      elif [ $IN_TERM -ne 0 ] && [[ ! "$THE_CHAR" =~ [a-zA-Z0-9_] ]]; then
         IN_TERM=0
      fi
   fi

   # If the '#' isn't being used to get the number of arguments ("$#") or the number of elements in an
   # array ("{#ARRAY[@]}"), and we're not inside a string, then we consider it a comment
   if [ "$THE_CHAR" == "#" ] && [ "$LAST_CHAR" != "$" ] && [ "$LAST_CHAR" != "{" ] && [ $IN_SINGLE_QUOTE -eq 0 ] && [ $IN_DOUBLE_QUOTE -eq 0 ]; then
      #echo "Entered comment on line $CUR_LINE."
      IN_COMMENT=1
   # Reset in-comment status if we hit a newline
   elif [ "$THE_CHAR" == "
" ]; then
      #echo Hit newline
      let CUR_LINE+=1
      CUR_CHAR=0
      IN_COMMENT=0
   # If we hit a single-quote character and it wasn't escaped and we're not already in a string, a
   # string has started or ended, so flip our boolean
   elif [ "$THE_CHAR" == "'" ] && [ "$LAST_CHAR" != "\\" ] && [ $IN_DOUBLE_QUOTE -eq 0 ] && [ $IN_COMMENT -eq 0 ]; then
      IN_SINGLE_QUOTE=$((IN_SINGLE_QUOTE ^= 1))
      #echo "IN_SINGLE_QUOTE changed to $IN_SINGLE_QUOTE on line $CUR_LINE col $CUR_CHAR."
   # Same for a double-quote character
   elif [ "$THE_CHAR" == "\"" ] && [ "$LAST_CHAR" != "\\" ] && [ $IN_SINGLE_QUOTE -eq 0 ] && [ $IN_COMMENT -eq 0 ]; then
      IN_DOUBLE_QUOTE=$((IN_DOUBLE_QUOTE ^= 1))
      #echo "IN_DOUBLE_QUOTE changed to $IN_DOUBLE_QUOTE on line $CUR_LINE col $CUR_CHAR."
   fi

   # Keep adding the latest character to the term we're building if we're still in it...
   if [ $IN_TERM -eq 1 ]; then
      LAST_TERM+="$THE_CHAR"
   # ...otherwise, if we're done iterating over a term, add it to SCRIPT_TEXT_TERMS if it's more than
   # one character
   elif [ $IN_TERM -eq 0 ] && [ ! -z "$LAST_TERM" ]; then
      #echo "Found term $LAST_TERM"
      if [ ${#LAST_TERM} -gt 1 ]; then
         SCRIPT_TEXT_TERMS+=("$LAST_TERM")
      fi
      LAST_TERM=""
   fi

   LAST_CHAR="$THE_CHAR"
done
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
   unset SCRIPT_TEXT_REMAINDER
   declare -a SCRIPT_TEXT_REMAINDER=()
   echo "${#ARRAY_TO_FILTER[*]} term(s) left to filter: ${ARRAY_TO_FILTER[@]}."
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
            #echo "Matched filter term $THE_VAR against ${ARRAY_TO_FILTER[$i]}."
            MATCH=1
            break
         fi
      done
      if [ $MATCH -ne 1 ]; then
         #echo "Adding ${ARRAY_TO_FILTER[$i]} to SCRIPT_TEXT_REMAINDER."
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

if [ ${#SCRIPT_TEXT_REMAINDER[@]} -gt 0 ]; then
   echo "The following ${#SCRIPT_TEXT_REMAINDER[@]} commands appear to be third-party programs not built into Bash:"
   for ((i = 0; i < ${#SCRIPT_TEXT_REMAINDER[@]}; ++i)); do
      echo "${SCRIPT_TEXT_REMAINDER[$i]}"
   done
else
   echo "All the commands used in this script are built into Bash."
fi