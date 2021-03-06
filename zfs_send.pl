#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use POSIX qw(strftime);
use Data::Dumper;

my $src_root;
my $dst_root;
my $remote_host;
my $filter;
my $last_snap;
my $src;
my $dst;
my $remote_zfs;
my $rsync;
my $block_size;
my $debug = 0;
my $progress = 0;
my $force = 0;

sub init{
	GetOptions(
		q(source|src=s) => \$src_root, 
		q(destination|dst=s) => \$dst_root, 
		q(host=s) => \$remote_host, 
		q(filter=s) => \$filter, 
		q(snapshot=s) => \$last_snap, 
		q(block-size=s) => \$block_size, 
		q(debug) => \$debug,
		q(progress) => \$progress,
		q(force) => \$force,
	);
	
	print_usage() if not defined $src_root;
	$dst_root = $src_root if not defined $dst_root;
	$block_size = 131072 if not defined $block_size;
	$filter = q() if not defined $filter;
	
	my $rsync_format = q(=) x 28 . q( %i %n);
	my $rsync_opts = q();
	$rsync_opts .= q( --progress) if $progress;
	if (defined $remote_host){
		my $ssh = q(ssh -c arcfour);
		$remote_zfs = qx($ssh $remote_host which zfs);
		$remote_zfs = qq($ssh $remote_host $remote_zfs);
		chomp $remote_zfs;
		my $remote_rsync = qx($ssh $remote_host which rsync);
		chomp $remote_rsync;
		$rsync = qq(rsync -ai $rsync_opts --out-format='$rsync_format' --block-size=$block_size --inplace --no-whole-file --rsync-path='$remote_rsync' -e '$ssh');
		$remote_host .= q(:);
	} else {
		$remote_host = q();
		if ($src_root eq $dst_root){
			print STDERR qq(Source and destination cannot be equal at local transfer\n);
			print_usage();
		} else {
			$remote_zfs = q(zfs);
			$rsync = qq(rsync -aui $rsync_opts --out-format='$rsync_format' --block-size=$block_size --inplace --no-whole-file);
		}
	}
}

sub echo{
	my ($message) = @_;
	print strftime qq(%Y-%m-%d %H:%M:%S > ), localtime;
	print $message;
}

sub print_usage{
	my $usage = qq(Usage: $0 --source=<source filesystem> --destination=<destination filesystem> [--host=<[username@]host>] [-snapshot=<last snapshot>] [--filter=<exclude filter>]\n);
	print $usage;
	exit;
}

sub get_zfs_tree{
	my ($zfs, $root) = @_;
	my @fields = qw(name type creation mountpoint origin used);
	my $tree;
	my $id = 0;
	my $cmd = qq($zfs list -r -H -t all -o ) . join(q(,), @fields) . qq( -s creation $root 2>/dev/null);
	echo qq(=== $cmd\n) if $debug;
	open my $zfs_list, q(-|), $cmd or die $!;
	while (<$zfs_list>){
		chomp;
		my @values = split /\t/;
		my %hash;
		@hash{@fields} = map { (my $foo = $_) =~ s|^$root/?||; $foo } @values;
		next if $filter ne q() and $hash{name} =~ m#$filter#;
		#s|^$root/?|| for @values;
		#@hash{@fields} = @values;
		my $dataset = shift @values;
		my $name = $hash{name};
		$tree->{$name} = \%hash;
		$tree->{$name}->{dataset} = $dataset;

		if ($tree->{$name}->{origin} eq q(-)){
			delete $tree->{$name}->{origin};
		} elsif (defined $tree->{ $tree->{$name}->{origin} }){
			$tree->{$name}->{origin} = $tree->{ $tree->{$name}->{origin} };
		} else {
			# origin was filtered out?
			delete $tree->{$name};
			next;
		}
		$tree->{$name}->{id} = $id++;
		
		if ($tree->{$name}->{type} eq q(snapshot)){
			my ($parent, $snapshot) = split(/@/, $name);
			$tree->{$name}->{parent} = $tree->{$parent};
			$tree->{$name}->{snapshot} = $snapshot;
			if (defined $tree->{$name}->{parent}){
				$tree->{$name}->{src_path} = qq($tree->{$name}->{parent}->{mountpoint}/.zfs/snapshot/$tree->{$name}->{snapshot}/);
				$tree->{$name}->{mountpoint} = $tree->{$name}->{parent}->{mountpoint};
			}
		} else {
			$tree->{$name}->{parent} = $tree->{$name};
			$tree->{$name}->{src_path} = $tree->{$name}->{mountpoint};
		}
		if ($debug == 2){
			print Dumper($tree);
			local( $| ) = ( 1 );
			print q(Press <Enter> to continue: );
			my $resp = <STDIN>;
		}
	}
	close $zfs_list;
	return $tree;
}

sub compare{
	my ($src, $dst) = @_;
	my $failed = 0;
	my $res;
	for my $name (sort {$src->{$a}->{id} <=> $src->{$b}->{id}} grep {$src->{$_}->{type} eq q(snapshot)} keys %$src){
		if (defined $dst->{$name}){
			$src->{$name}->{parent}->{last_common_snapshot} = $src->{$name} unless defined $src->{$name}->{parent}->{first_missing_snapshot};
			$dst->{$name}->{parent}->{last_common_snapshot} = $dst->{$name} unless defined $dst->{$name}->{parent}->{first_missing_snapshot};
		} else { # for future use
			$src->{$name}->{parent}->{first_missing_snapshot} = $src->{$name} unless defined $src->{$name}->{parent}->{first_missing_snapshot};
			$src->{$name}->{parent}->{last_missing_snapshot} = $src->{$name};
			$res->{$name} = $src->{$name};
		}
	}
	for my $name (sort {$src->{$a}->{id} <=> $src->{$b}->{id}} grep {$src->{$_}->{type} eq q(filesystem)} keys %$src){
		if (defined $src->{$name}->{last_common_snapshot}){
			my $diff = $dst->{$name}->{last_common_snapshot}->{used};
			if ($src->{$name}->{last_common_snapshot}->{snapshot} ne $last_snap){
				if ($diff !~ /^0|1K$/){
					echo qq(!!! Destination $src->{$name}->{dataset} differs from last common snapshot on $diff. Probably you need to run on remote host:\nzfs rollback -R $dst->{$name}->{last_common_snapshot}->{dataset}\n\n);
					$failed++;
				}
				$res->{$name} = $src->{$name};
			}
		} else {
			#if (defined $dst->{$name} and $dst->{$name}->{used} ne q(0)){
			if (defined $dst->{$name} and $dst->{$name}->{used} !~ /^0|1K$/){
				echo qq(!!! Destination $src->{$name}->{dataset} exists, but has no common snapshots with $name. Probably you need to execute on remote host:\nzfs destroy $src->{$name}->{dataset}\n\n);
				$failed++;
			}
			$res->{$name} = $src->{$name};
		}
	}
	return ($res, $failed);
}

sub echo_names{
	my ($tree) = @_;
	for my $name (sort {$tree->{$a}->{id} <=> $tree->{$b}->{id}} keys %$tree){
		echo qq($tree->{$name}->{dataset}\n);
	}
}

sub transfer{
	my ($src, $dst) = @_;
	for my $name (sort {$src->{$a}->{id} <=> $src->{$b}->{id}} keys %$src){
		print qq(\n);
		echo qq(= $src->{$name}->{dataset}\n);
		# skip if dataset doesn't exist anymore
		if (system(qq(zfs list $src->{$name}->{dataset} >/dev/null 2>&1)) != 0){
			echo qq(Dataset $src->{$name}->{dataset} doesn't exist anymore\n);
			next;
		}

		for my $key (keys %{$src->{$name}}){
			$dst->{$name}->{$key} = $src->{$name}->{$key};
		}
		$dst->{$name}->{dataset} =~ s|^$src_root|$dst_root|;
		$dst->{$name}->{parent} = $dst->{ $src->{$name}->{parent}->{name} }; 
		$dst->{$name}->{origin} = $dst->{ $src->{$name}->{origin}->{name} } if defined $src->{$name}->{origin}; 

		if ($src->{$name}->{type} eq q(filesystem)){
			if (system(qq($remote_zfs list $dst->{$name}->{dataset} >/dev/null 2>&1)) != 0){
				if (! defined $dst->{$name}->{origin}){
					my $cmd = qq($remote_zfs create $dst->{$name}->{dataset});
					echo qq(=== $cmd ) if $debug;
					system($cmd) == 0 or die qq("$cmd" failed: $?);
				} else {
					my $cmd = qq($remote_zfs clone $dst->{$name}->{origin}->{dataset} $dst->{$name}->{dataset});
					echo qq(=== $cmd ) if $debug;
					system($cmd) == 0 or die qq("$cmd" failed: $?);
				}
			}
			$dst->{$name}->{mountpoint} = qx($remote_zfs get -H -o value mountpoint $dst->{$name}->{dataset});
			chomp $dst->{$name}->{mountpoint};
		} else {
			die qq(Directory $src->{$name}->{src_path} does not exist. Make sure it is mounted.) if not -d $src->{$name}->{src_path};
			my $cmd = qq($rsync $src->{$name}->{src_path} $remote_host$dst->{$name}->{parent}->{mountpoint});
			echo qq(=== $cmd ) if $debug;
			system($cmd) == 0 or die qq("$cmd" failed: $?);

			$cmd = qq($remote_zfs snapshot $dst->{$name}->{dataset});
			echo qq(=== $cmd ) if $debug;
			system($cmd) == 0 or die qq("$cmd" failed: $?);
		}
	}
}

sub main{
	init();
	my $src = get_zfs_tree(q(zfs), $src_root);
	my $dst = get_zfs_tree($remote_zfs, $dst_root);
	my ($src_res, $failed) = compare($src, $dst);
	$Data::Dumper::Sortkeys = 1;
	print Dumper($src, $dst) if $debug;
	if ($failed){
		if ($force){
			local( $| ) = ( 1 );
			print q(Press <Enter> to continue: );
			my $resp = <STDIN>;
		} else {
			die ("Something is wrong on remote host.");
		}
	}
	#$Data::Dumper::Sortkeys = sub { [sort {$b cmp $a} keys %{$_[0]}] }; # http://stackoverflow.com/questions/7466825/how-do-you-sort-the-output-of-datadumper-perl
	transfer($src_res, $dst);
}

main();
