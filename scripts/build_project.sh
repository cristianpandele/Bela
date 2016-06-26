#!/bin/sh
#
# This script compiles a Bela project on the BeagleBone Black and
# optionally runs it. Pass a directory path in the first argument. 
# The source files in this directory are copied to the board and compiled.
# set defaults unless variables are already set

SCRIPTDIR=$(dirname "$0")
[ -z $SCRIPTDIR ] && SCRIPTDIR="./" || SCRIPTDIR=$SCRIPTDIR/ 
. $SCRIPTDIR.bela_common || { echo "You must be in Bela/scripts to run these scripts" | exit 1; }  

usage_brief(){
	printf "Usage: $THIS_SCRIPT path/to/project "
	build_script_usage_brief
	run_script_usage_brief
	echo
}


usage()
{
	usage_brief
	echo "

	This script copies a directory of source files to the BeagleBone, compiles
	and runs it. The Bela core files should have first been copied over
	using the \`update_board' script once.
	
	Folder /path/to/project should contain at least one .c, .cpp, .S or .pd file.
"
	build_script_usage
	run_script_usage
}

RUN_MODE=foreground

WATCH=0
HOST_SOURCE_PATH=
BBB_PROJECT_NAME=
FORCE=0
EXPERT=0
while [ -n "$1" ]
do
	case $1 in
		-c)
			shift;
			COMMAND_ARGS="$1";
		;;
		-b)
			RUN_MODE=screen;
		;;
		-f)
			RUN_MODE=foreground;
		;;
		-s)
			RUN_MODE=screenfg;
		;;
		-n)
			RUN_PROJECT=0;
		;;
		-p)
			shift;
			BBB_PROJECT_NAME="$1";
		;;	
		--clean)
			BBB_MAKEFILE_OPTIONS="$BBB_MAKEFILE_OPTIONS projectclean";
		;;
		--force)
			FORCE=1
		;;
		-m)
			shift;
			BBB_MAKEFILE_OPTIONS="$BBB_MAKEFILE_OPTIONS $1";
		;;
		--watch)
			WATCH=1
		;;
		--help|-h|-\?)
			usage;
			exit 0;
		;;
		-*)
			echo Error: unknow option $0
			usage_brief
			exit 1;
		;;
		*)
			[ -z "$HOST_SOURCE_PATH" ] &&  HOST_SOURCE_PATH=$1 || {
				echo "Too many options $HOST_SOURCE_PATH $1"
				usage_brief
				exit 1;
			}
		;;
	esac
	shift
done

[ $FORCE -eq 1 ] && EXPERT=1

# Check that we have a directory containing at least one source file
# as an argument

if [ -z "$HOST_SOURCE_PATH" ]
then
	usage
	exit 2
fi

FIND_STRING="find $HOST_SOURCE_PATH -maxdepth 1 -type f "
EXTENSIONS_TO_FIND='\.cpp\|\.c\|\.S\|\.pd'
FOUND_FILES=$($FIND_STRING 2>/dev/null | grep "$EXTENSIONS_TO_FIND")
if [ -z "$FOUND_FILES" ]
then
	 printf "ERROR: Please provide a directory containing .c, .cpp, .S or .pd files.\n\n"
	 exit 1
fi

[ -z $BBB_PROJECT_NAME ] && BBB_PROJECT_NAME=`basename "$HOST_SOURCE_PATH"` 

BBB_PROJECT_FOLDER=$BBB_PROJECT_HOME"/"$BBB_PROJECT_NAME #make sure there is no trailing slash here
BBB_NETWORK_TARGET_FOLDER=$BBB_ADDRESS:$BBB_PROJECT_FOLDER

[ $EXPERT -eq 0 ] && check_board_alive
# Not sure if set_date should be taken out by expert mode ...
# The expert will have to remember to run set_date after powering up the board 
# in case the updated files are not being rebuilt
[ $EXPERT -eq 0 ] && set_date

# stop running process
echo "Stop running process..."
ssh $BBB_ADDRESS make QUIET=true --no-print-directory -C $BBB_BELA_HOME stop

# check if project exists
[ $FORCE -eq 1 ] || {
	check_project_exists $BBB_PROJECT_NAME &&\
	{
		printf "Project \`$BBB_PROJECT_NAME' already exists on the board, do you want to overwrite it? Or use the \`-p' option to specify a different name" 
		interactive 1 
		[  $_RET1 -eq 0 ] && {
			echo "Aborting..."
			exit;
		}
	}
}

# This file is used to keep track of when the last upload was made,
# so to check for modifications if WATCH is active
reference_time_file="$SCRIPTDIR/../tmp/.time$BBB_PROJECT_NAME"
uploadBuildRun(){
	[ $WATCH -eq 1 ] && touch $reference_time_file
	# Copy new source files to the board
	echo "Copying new source files to BeagleBone..."
	if [ -z "`which rsync`" ];
	then
		#if rsync is not available, brutally clean the destination folder
		ssh bbb "make --no-print-directory -C $BBB_BELA_HOME sourceclean PROJECT=$BBB_PROJECT_NAME";
		#and copy over all the files again
		scp -r $HOST_SOURCE_PATH "$BBB_NETWORK_TARGET_FOLDER"
	else
		#rsync 
		# --delete makes sure it removes files that are not in the origin folder
		# -c evaluates changes using md5 checksum instead of file date, so we don't care about time skews 
		# --no-t makes sure file timestamps are not preserved, so that the Makefile will not think that targets are up to date when replacing files on the BBB
		#  with older files from the host. This will solve 99% of the issues with Makefile thinking a target is up to date when it is not.
		rsync -ac --out-format="   %n" --no-t --delete-after --exclude=$BBB_PROJECT_NAME --exclude=build $HOST_SOURCE_PATH"/" "$BBB_NETWORK_TARGET_FOLDER/" #trailing slashes used here make sure rsync does not create another folder inside the target folder
	fi

	if [ $? -ne 0 ]
	then
		echo "Error while copying files"
		exit
	fi

	# Make new Bela executable and run
	MAKE_COMMAND="make --no-print-directory QUIET=true -C $BBB_BELA_HOME PROJECT='$BBB_PROJECT_NAME' CL='$COMMAND_ARGS' $BBB_MAKEFILE_OPTIONS"
	if [ $RUN_PROJECT -eq 0 ]
	then
		echo "Building project..."
		ssh $BBB_ADDRESS "$MAKE_COMMAND"
	else
        echo "Building and running project..."
	    case_run_mode
	fi
}
# run it once and then (in case) start waiting for changes
uploadBuildRun

if [ $WATCH -ne 0 ]; then
	while true
	do
		echo "Waiting for changes in $HOST_SOURCE_PATH, or press ctrl-c to terminate"
		CORE_DIR="$SCRIPTDIR/../core"
		INCLUDE_DIR="$SCRIPTDIR/../include"
		wait_for_change $HOST_SOURCE_PATH "$reference_time_file" && {
			echo "Content of "$HOST_SOURCE_PATH" has changed"
		}
		echo "Files changed"
		uploadBuildRun
	done
fi