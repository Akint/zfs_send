# zfs_send.pl

This script is written for the situation, when you need to change block size on the whole ZFS tree. The script reproduces the whole lifecycle of source FS by *rsync*ing it since the 1st snapshot.

	Usage: ./zfs_send.pl --source=<source filesystem> --destination=<destination filesystem> [--host=<[username@]host>] [-snapshot=<last snapshot>] [--filter=<exclude filter>]

If host is not specified, the script will produce local copy.
If last snapshot is not specified, the script will sync all snapshots it can find.

Example:

	# zfs list -r rpool/test rpool/test2
	cannot open 'rpool/test2': dataset does not exist
	rpool/test                      2.62G  29.4G    34K  /rpool/test
	rpool/test@send                   18K      -    34K  -
	rpool/test/db1                  1.85G  29.4G   993M  /rpool/test/db1
	rpool/test/db1@1                 508M      -   993M  -
	rpool/test/db1@2                 389M      -   993M  -
	rpool/test/db1@send                 0      -   993M  -
	rpool/test/db1_1                 695M  29.4G   993M  /rpool/test/db1_1
	rpool/test/db1_1@send               0      -   993M  -
	rpool/test/db1_2                99.3M  29.4G   993M  /rpool/test/db1_2
	rpool/test/db1_2@send               0      -   993M  -
	
	# ./zfs_send.pl --source=rpool/test --destination=rpool/test2
	
	2015-06-22 13:15:07 > = rpool/test
	
	2015-06-22 13:15:07 > = rpool/test/db1
	
	2015-06-22 13:15:07 > = rpool/test/db1@1
	============================ .d..t...... ./
	============================ >f+++++++++ file.bin
	
	2015-06-22 13:15:40 > = rpool/test/db1_1
	
	2015-06-22 13:15:40 > = rpool/test/db1@2
	============================ >f..t...... file.bin
	
	2015-06-22 13:16:28 > = rpool/test/db1_2
	
	2015-06-22 13:16:28 > = rpool/test@send
	============================ .d..t...... ./
	============================ .d..t...... db1/
	============================ .d..t...... db1_1/
	============================ .d..t...... db1_2/
	
	2015-06-22 13:16:28 > = rpool/test/db1@send
	============================ .d..t...... ./
	============================ >f..t...... file.bin
	
	2015-06-22 13:17:10 > = rpool/test/db1_1@send
	============================ .d..t...... ./
	============================ >f..t...... file.bin
	
	2015-06-22 13:18:05 > = rpool/test/db1_2@send
	============================ .d..t...... ./
	============================ >f..t...... file.bin
	
	# zfs list -r rpool/test rpool/test2
	NAME                     USED  AVAIL  REFER  MOUNTPOINT
	rpool/test              2.62G  29.4G    34K  /rpool/test
	rpool/test@send           18K      -    34K  -
	rpool/test/db1          1.85G  29.4G   993M  /rpool/test/db1
	rpool/test/db1@1         508M      -   993M  -
	rpool/test/db1@2         389M      -   993M  -
	rpool/test/db1@send         0      -   993M  -
	rpool/test/db1_1         695M  29.4G   993M  /rpool/test/db1_1
	rpool/test/db1_1@send       0      -   993M  -
	rpool/test/db1_2        99.3M  29.4G   993M  /rpool/test/db1_2
	rpool/test/db1_2@send       0      -   993M  -
	rpool/test2             2.62G  29.4G    34K  /rpool/test2
	rpool/test2@send            0      -    34K  -
	rpool/test2/db1         1.85G  29.4G   993M  /rpool/test2/db1
	rpool/test2/db1@1        508M      -   993M  -
	rpool/test2/db1@2        389M      -   993M  -
	rpool/test2/db1@send        0      -   993M  -
	rpool/test2/db1_1        695M  29.4G   993M  /rpool/test2/db1_1
	rpool/test2/db1_1@send      0      -   993M  -
	rpool/test2/db1_2       99.3M  29.4G   993M  /rpool/test2/db1_2
	rpool/test2/db1_2@send      0      -   993M  -
	
