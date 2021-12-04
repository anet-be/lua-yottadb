#!/bin/bash
#################################################################
#								#
# Copyright (c) 2021 YottaDB LLC and/or its subsidiaries.	#
# All rights reserved.						#
#								#
#	This source code contains the intellectual property	#
#	of its copyright holder(s), and is made available	#
#	under a license.  If you do not know the terms of	#
#	the license, please stop and do not read further.	#
#								#
#################################################################

$1/yottadb -run ^GDE <<FILE
change -r DEFAULT -key_size=1019 -record_size=1048576
change -segment DEFAULT -file_name=$2
change -r DEFAULT -NULL_SUBSCRIPTS=true
exit
FILE

$1/mupip create
