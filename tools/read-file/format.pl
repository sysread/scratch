#!/usr/bin/env perl

#-------------------------------------------------------------------------------
# format.pl - line-numbered, hash-annotated file reader
#
# Single-process formatter that reads a file, computes a whole-file SHA-256
# guardian hash, and emits each line with a 4-char hex hash derived from
# the guardian hash, line number, and line content. This means every line
# hash self-invalidates when the file changes anywhere.
#
# Arguments:
#   $ARGV[0]  canonical file path
#   $ARGV[1]  offset (1-based start line, 0 = from beginning)
#   $ARGV[2]  limit  (max lines to show, 0 = all)
#   $ARGV[3]  previous guardian hash (empty = first read)
#   $ARGV[4]  max file size in bytes
#
# Stdout: formatted output for the LLM (header + annotated lines)
# fd 3:   guardian hash (captured by bash wrapper via temp file)
# Stderr: error messages (triggers tool failure)
#-------------------------------------------------------------------------------

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Digest::MD5 qw(md5_hex);

my ($path, $offset, $limit, $prev_hash, $max_size) = @ARGV;

$offset   //= 0;
$limit    //= 0;
$prev_hash //= '';
$max_size //= 2 * 1024 * 1024;  # 2MB default

# --- Validation ---

unless (-e $path) { print STDERR "read-file: file not found: $path\n"; exit 1; }
unless (-f $path) { print STDERR "read-file: not a regular file: $path\n"; exit 1; }
if (-B $path)     { print STDERR "read-file: binary file detected: $path\n"; exit 1; }

my $size = -s $path;
if ($size > $max_size) {
    my $mb = sprintf("%.1f", $size / (1024 * 1024));
    my $cap_mb = sprintf("%.1f", $max_size / (1024 * 1024));
    print STDERR "read-file: file too large (${mb}MB, cap ${cap_mb}MB): $path\n";
    exit 1;
}

# --- Read and hash ---

open(my $fh, '<', $path) or die "read-file: cannot open $path: $!\n";
my $contents = do { local $/; <$fh> };
close($fh);

my $guardian = sha256_hex($contents);

# Split into lines, preserving trailing empty line if file ends with newline.
# Remove \r for Windows line endings.
$contents =~ s/\r\n/\n/g;
my @lines = split(/\n/, $contents, -1);

# split with -1 keeps a trailing empty element if the file ends with \n.
# That trailing element isn't a real line -- remove it.
pop @lines if @lines && $lines[-1] eq '' && $contents =~ /\n$/;

my $total = scalar @lines;

# --- Compute display range ---

my $start = ($offset > 0) ? $offset : 1;
my $end;

if ($start > $total) {
    # Offset past end of file -- print header + note, no lines
    print "[file: $path, lines: 0 of $total, hash: $guardian]\n";
    print "[note: offset $start is past end of file ($total lines)]\n";

    if ($prev_hash ne '' && $prev_hash ne $guardian) {
        print "[note: file changed since previous read]\n";
    }

    # Write guardian hash to fd 3
    if (open(my $hfd, '>&=', 3)) {
        print $hfd $guardian;
        close($hfd);
    }

    exit 0;
}

if ($limit > 0) {
    $end = $start + $limit - 1;
    $end = $total if $end > $total;
} else {
    $end = $total;
}

# --- Output ---

print "[file: $path, lines: $start-$end of $total, hash: $guardian]\n";

if ($prev_hash ne '' && $prev_hash ne $guardian) {
    print "[note: file changed since previous read]\n";
}

print "\n";

# Line number field width: enough for the largest line number in the range
my $numwidth = length("$end");
$numwidth = 6 if $numwidth < 6;

for my $i ($start .. $end) {
    my $line = $lines[$i - 1];  # 0-indexed array, 1-indexed display
    my $hash = substr(md5_hex("$guardian\t$i\t$line"), 0, 4);

    if ($line eq '') {
        printf "%${numwidth}d  %s\n", $i, $hash;
    } else {
        printf "%${numwidth}d  %s  %s\n", $i, $hash, $line;
    }
}

# --- Write guardian hash to fd 3 ---

if (open(my $hfd, '>&=', 3)) {
    print $hfd $guardian;
    close($hfd);
}
