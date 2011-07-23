#!/usr/bin/perl -w

######################################################################
#
# This Delta debugger specifically targets C code. Its design point --
# in two different senses -- is to be complementary to a line-based
# Delta like this one:
#
#   http://delta.tigris.org/
#
# The first sense is that c_delta aims for maximum reduction and
# specifically targets transformations not available to a
# language-independent Delta debugger. For example, c_delta makes
# coordinated changes across the whole program: remove an array
# dimension, remove a function argument, reorder function calls.
#
# Second, c_delta is stupid in the sense that it generates a lot of
# invalid code and also most of its changes do not reduce program size
# by a large amount. Thus, it is best used as a second pass with a
# faster Delta like the Berkeley one trimming the obviously irrelevant
# code. Actually, generating syntactically invalid code is not a
# performance problem at all: these are discarded very quickly be a
# typical "interestingness" script. The vast majority of a Delta's
# time is spent checking interestingness of syntactically valid code.
#
####################################################################

# TODO:

# turn a union type into a struct
# remove argument from function, including all calls
# transform a function to return void
# inline a function call
#   only for small functions, and only when delta has already
#   gotten pretty far
# remove function call from its enclosing expression
#   look for preceding semicolon or open curly brace
# move arguments and locals to global scope
# remove level of pointer indirection
# remove array dimension
# do copy propagation
#   especially try to replace calls and arguments with available exprs
# replace for-loops with expressions guessed from initializers
#   guess that it executes 0 and 1 times

# get speedup by adding fast bailouts from test scripts
#   super-fast: just runs one compiler at -O0 look for syntactical correctness
#   medium fast: looks for checksum differences, runs valgrind, etc.
#   full: runs chucky's tool
#   can also batch up transformations (like delete parens) that
#     usually succeed without running any test

# parameters
#   Cp = cost of a passed test
#   Cf = cost of a failed test, say half the cost of a passed test
#   S  = fraction of transformations that succeed
#   N  = number of attempted transformations
#   assumption: test are independent
#   assumption: c_delta has negligible running time

# if test is run every time
#  Cp*S*N + Cf*(1-S)*N

# if K transformations are run before running any test
# SS = S^K, NN = N/K
# Cp*SS*NN + Cf(1-SS)*NN

# test this and then work out the math when cheaper tests exist
# need to measure some runs and estimate the values of constants

# watch for unexpected abnormal compiler outputs

# long term: rewrite this tool to operate on ASTs
#   need a tool that can pretty-print almost exactly the original code

######################################################################

use strict;
use Regexp::Common;
use re 'eval';

######################################################################

my $DEBUG = 0;
my $INDENT_OPTS = "-bad -bap -bc -cs -pcs -prs -saf -sai -saw -sob -ss -bl ";

######################################################################

my $varnum = "(\\-?|\\+?)[0-9a-zA-Z\_]+";
my $varnumexp = "($varnum)|($RE{balanced}{-parens=>'()'})";
my $field = "\\.($varnum)";
my $index = "\\\[($varnum)\\\]";
my $fullvar = "([\\&\\*]*)($varnumexp)(($field)|($index))*";
my $arith = "\\+|\\-|\\%|\\/|\\*";
my $comp = "\\<\\=|\\>\\=|\\<|\\>|\\=\\=|\\!\\=|\\=";
my $logic = "\\&\\&|\\|\\|";
my $bit = "\\||\\&|\\^|\\<\\<|\\>\\>";
my $binop = "($arith)|($comp)|($logic)|($bit)";
my $border = "[\\*\\{\\(\\[\\:\\,\\}\\)\\]\\;\\,]";
my $borderorspc = "(($border)|(\\s))";
my $rettype = "int|void|short|long|char|signed|unsigned|const|static|(union\\s+U[0-9]+)|(struct\\s+S[0-9+])";
my $functype = "(($rettype)\\s*|\\*\\s*)+";
my $fname = "(?<fname>$varnum)";
my $funcstart_free = "$functype\\s+(?<fname>$varnum)\\s*$RE{balanced}{-parens=>'()'}";
my $funcstart = "$functype\\s+XXX\\s*$RE{balanced}{-parens=>'()'}";
my $proto = "$funcstart;";
my $func = "$funcstart\\s*$RE{balanced}{-parens=>'{}'}";
my $func_free = "$funcstart_free\\s*$RE{balanced}{-parens=>'{}'}";
my $call = "$varnum\\s*$RE{balanced}{-parens=>'()'}";

# these match without additional qualification
my @regexes_to_replace = (
    ["$RE{balanced}{-parens=>'()'}", ""],
    ["$RE{balanced}{-parens=>'{}'}", ""],
    ["=\\s*$RE{balanced}{-parens=>'{}'}", ""],
    ["\\:\\s*[0-9]+\\s*;", ";"],
    ["\\;", ""],
    ["\\^\\=", "="],
    ["\\|\\=", "="],
    ["\\&\\=", "="],
    ["\\+\\=", "="],
    ["\\-\\=", "="],
    ["\\*\\=", "="],
    ["\\/\\=", "="],
    ["\\%\\=", "="],
    ["\\<\\<\\=", "="],
    ["\\>\\>\\=", "="],
    ["\\+", ""],
    ["\\-", ""],
    ["\\!", ""],
    ["\\~", ""],
    ['"(.*?)"', ""],
    ['"(.*?)",', ""],
    );

# these match when preceded and followed by $borderorspc
my @delimited_regexes_to_replace = (
    ["($varnumexp)\\s*:", ""],
    ["goto\\s+($varnum);", ""],
    ["char", "int"],
    ["short", "int"],
    ["long", "int"],
    ["signed", "int"],
    ["unsigned", "int"],
    ["int argc, char \\*argv\\[\\]", "void"],
    ["int.*?;", ""],
    ["for", ""],
    ["if\\s+\\(.*?\\)", ""],
    ["struct.*?;", ""],
    ["union.*?;", ""],
    ["($functype)\\s*($varnum)\\s*$RE{balanced}{-parens=>'()'}\\s*$RE{balanced}{-parens=>'{}'}", ""],
    ["$call,", "0"],
    ["$call,", ""],
    ["$call", "0"],
    ["$call", ""],
    );

my @subexprs = (
    "($fullvar)(\\s*)($binop)(\\s*)($fullvar)",
    "($fullvar)(\\s*)($binop)",
    "($binop)(\\s*)($fullvar)",
    "($fullvar)",
    "($fullvar)(\\s*\\?\\s*)($fullvar)(\\s*\\:\\s*)($fullvar)",
    );

foreach my $x (@subexprs) {
    push @delimited_regexes_to_replace, ["$x", "0"];
    push @delimited_regexes_to_replace, ["$x", "1"];
    push @delimited_regexes_to_replace, ["$x", ""];
    push @delimited_regexes_to_replace, ["$x\\s*,", "0,"];
    push @delimited_regexes_to_replace, ["$x\\s*,", "1,"];
    push @delimited_regexes_to_replace, ["$x\\s*,", ""];
    push @delimited_regexes_to_replace, [",\\s*$x", ""];
}

my %regex_worked;
my %regex_failed;
my %delimited_regex_worked;
my %delimited_regex_failed;
for (my $n=0; $n<scalar(@regexes_to_replace); $n++) {
    $regex_worked{$n} = 0;
    $regex_failed{$n} = 0;
}
for (my $n=0; $n<scalar(@delimited_regexes_to_replace); $n++) {
    $delimited_regex_worked{$n} = 0;
    $delimited_regex_failed{$n} = 0;
}

######################################################################

my $prog;
my $orig_prog_len;

sub print_pct () {
    my $pct = 100 - (length($prog)*100.0/$orig_prog_len);
    printf "(%.1f %%)\n", $pct;
}

sub find_match ($$$) {
    (my $p2, my $s1, my $s2) = @_;
    my $count = 1;
    die if (!(defined($p2) && defined($s1) && defined($s2)));
    while ($count > 0) {
	return -1 if ($p2 >= (length ($prog)-1));
	my $s = substr($prog, $p2, 1);
	if (!defined($s)) {
	    my $l = length ($prog);
	    print "$p2 $l\n";
	    die;
	}
	$count++ if ($s eq $s1);
	$count-- if ($s eq $s2);
	$p2++;
    }
    return $p2-1;
}

# these are set at startup time and never change
my $cfile;
my $test;
my $trial_num = 0;   

sub read_file () {
    open INF, "<$cfile" or die;
    $prog = "";
    while (my $line = <INF>) {
	$prog .= $line;
    }
    if (substr($prog, 0, 1) ne " ") {
	$prog = " $prog";
    }
    if (substr ($prog, -1, 1) ne " ") {
	$prog = "$prog ";
    }
    close INF;
}

sub save_copy ($) {
    (my $fn) = @_;
    open OUTF, ">$fn" or die;
    print OUTF $prog;
    close OUTF;
}

sub write_file () {
    if (defined($DEBUG) && $DEBUG) {
	save_copy ("delta_tmp_${trial_num}.c");
    }
    $trial_num++;
    open OUTF, ">$cfile" or die;
    print OUTF $prog;
    close OUTF;
}

sub runit ($) {
    (my $cmd) = @_;
    if ((system "$cmd") != 0) {
	return -1;
    }   
    return ($? >> 8);
}

sub run_test () {
    my $res = runit "./$test >/dev/null 2>&1";
    return ($res == 0);
}

my %cache = ();
my $cache_hits = 0;
my $good_cnt;
my $bad_cnt;
my $pass_num = 0;
my $pos;
my %method_worked = ();
my %method_failed = ();
my $old_size = 1000000000;
 
sub delta_test ($$) {
    (my $method, my $ok_to_enlarge) = @_;
    my $len = length ($prog);
    print "[$pass_num $method ($pos / $len) s:$good_cnt f:$bad_cnt] ";

    my $result = $cache{$prog};

    if (defined($result)) {
	$cache_hits++;
	print "(hit) ";
	print "failure\n";
	read_file ();    
	$bad_cnt++;
	$method_failed{$method}++;
	return 0;
    }
    
    write_file ();
    $result = run_test ();
    $cache{$prog} = $result;
    
    if ($result) {
	print "success ";
	print_pct();
	system "cp $cfile $cfile.bak";
	$good_cnt++;
	$method_worked{$method}++;
	my $size = length ($prog);
	die if (($size > $old_size) && !$ok_to_enlarge);
	if ($size < $old_size) {
	    %cache = ();
	}
	$old_size = $size;
	return 1;
    } else {
	print "failure\n";
	system "cp $cfile.bak $cfile";
	read_file ();    
	$bad_cnt++;
	$method_failed{$method}++;
	return 0;
    }
}

sub sanity_check () {
    print "sanity check... ";
    my $res = run_test ();
    if (!$res) {
	die "test (and sanity check) fails";
    }
    print "successful\n";
}

sub find_func () {
    my $first = substr($prog, 0, $pos);
    my $rest = substr($prog, $pos);
    my $proto2 = $proto;
    die if (!($proto2 =~ s/XXX/$fname/));
    my $proto_start;
    my $proto_end;
    my $func_start;
    my $func_end;
    my $funcname;
    if ($rest =~ /^($proto2)/) {
	my $realproto = $1;
	$proto_start = length($first) + $-[0];
	$proto_end = length($first) + $+[0];
	$funcname = $+{fname};
	print "found prototype for '$funcname'\n";
	my $func2 = $func;
	die if (!($func2 =~ s/XXX/$funcname/));
	if ($rest =~ /($func2)/) {
	    my $body = $1;
	    $func_start = length ($first) + $-[0];
	    $func_end = length ($first) + $+[0];
	    print "got body as well\n";
	}
    } else {
	if ($rest =~ /^($func_free)/) {
	    my $body = $1;
	    $funcname = $+{fname};
	    $func_start = length ($first) + $-[0];
	    $func_end = length ($first) + $+[0];
	    print "got only body for $funcname\n";
	}
    }
    return ($funcname, $proto_start, $proto_end, $func_start, $func_end);
}

my %funcs_seen;

sub delta_pass ($) {
    (my $method) = @_;
    
    $pos = 0;
    $good_cnt = 0;
    $bad_cnt = 0;
    %funcs_seen = ();

    sanity_check();

    print "\n";
    print "========== starting pass <$method> ==========\n";

    while (1) {
	return ($good_cnt > 0) if ($pos >= length ($prog));
	my $worked = 0;

	if ($method eq "replace_regex") {
	    my $n=-1;
	    foreach my $l (@regexes_to_replace) {	       
		$n++;
		my $str = @{$l}[0];
		my $repl = @{$l}[1];
		my $first = substr($prog, 0, $pos);
		my $rest = substr($prog, $pos);
		my $rrest = $rest;
		if ($rest =~ s/(^$str)/$repl/) {
		    my $before = $1;
		    my $zz1 = $rest;
		    my $zz2 = $rrest;
		    ($zz1 =~ s/\s//g);
		    ($zz2 =~ s/\s//g);
		    if ($zz1 ne $zz2) {
			print "regex $n replacing '$before' with '$repl' : ";
			$prog = $first.$rest;
			if (delta_test ($method, 0)) {
			    #print "\n\n$zz1\n\n";
			    #print "\n\n$zz2\n\n";
			    $worked = 1;
			    $regex_worked{$n}++;
			} else {
			    $regex_failed{$n}++;
			}
		    }
		}
	    }
	    $n=-1;
	    foreach my $l (@delimited_regexes_to_replace) {
		$n++;
		my $str = @{$l}[0];
		my $repl = @{$l}[1];
		my $first = substr($prog, 0, $pos);
		my $rest = substr($prog, $pos);
		
		# avoid infinite replacement loops!
		next if ($repl eq "0" && $rest =~ /^($borderorspc)0$borderorspc/);
		next if ($repl =~ /0\s*,/ && $rest =~ /^($borderorspc)0\s*,$borderorspc/);
		next if ($repl eq "1" && $rest =~ /^($borderorspc)0$borderorspc/);
		next if ($repl =~ /1\s*,/ && $rest =~ /^($borderorspc)0\s*,$borderorspc/);
		next if ($repl eq "1" && $rest =~ /^($borderorspc)1$borderorspc/);
		next if ($repl =~ /1\s*,/ && $rest =~ /^($borderorspc)1,$borderorspc/);

		my $rrest = $rest;
		if ($rest =~ s/^(?<delim1>$borderorspc)(?<str>$str)(?<delim2>$borderorspc)/$+{delim1}$repl$+{delim2}/) {
		    my $before = $+{str};
		    my $zz1 = $rest;
		    my $zz2 = $rrest;
		    ($zz1 =~ s/\s//g);
		    ($zz2 =~ s/\s//g);
		    if ($zz1 ne $zz2) {
			print "regex $n delimited replacing '$before' with '$repl' : ";
			$prog = $first.$rest;
			if (delta_test ($method, 0)) {
			    $worked = 1;
			    $delimited_regex_worked{$n}++;
			} else {
			    $delimited_regex_failed{$n}++;
			}
		    }
		}
	    }
	} elsif ($method eq "all_blanks") {
	    if ($prog =~ s/\s{2,}/ /g) {
		$worked |= delta_test ($method, 0);
	    }
	    if ($prog =~ s/:(\S)/:\n$1/g) {
		$worked |= delta_test ($method, 1);
	    }
	    my $r1 = ($prog =~ s/,/ , /g);
	    my $r2 = ($prog =~ s/\s{2,}/ /g);
	    if ($r1 || $r2) {
		$worked |= delta_test ($method, 1);
	    }
	    return 0;
	} elsif ($method eq "blanks") {
	    my $first = substr($prog, 0, $pos);
	    my $rest = substr($prog, $pos);
	    if ($rest =~ s/^(\s{2,})/ /) {
		$prog = $first.$rest;
		$worked |= delta_test ($method, 0);
	    }
	} elsif ($method eq "indent") {	    
	    write_file();
	    system "indent $INDENT_OPTS $cfile";
	    read_file();
	    $worked |= delta_test ($method, 1);
	    return 0;
	} elsif ($method eq "crc") {
	    my $first = substr($prog, 0, $pos);
	    my $rest = substr($prog, $pos);
	    if ($rest =~ /^(?<all>transparent_crc\s*\((?<list>.*?)\))/) {
		my @stuff = split /,/, $+{list};
		my $var = $stuff[0];
		my $repl = "printf (\"%d\\n\", (int)$var)";
		print "crc call: < $+{all} > => < $repl > ";
		substr ($rest, 0, length ($+{all})) = $repl;
		$prog = $first.$rest;
		$worked |= delta_test ($method, 0);
	    }
	} elsif ($method eq "move_func") {
	    (my $func_name, my $proto_start, my $proto_end, my $func_start, my $func_end) = find_func();
	    if (defined($proto_start) && defined($func_start)) {
		my $proto = substr ($prog, $proto_start, $proto_end - $proto_start);
		my $bod = substr ($prog, $func_start, $func_end - $func_start, "");
		substr ($prog, $proto_start, $proto_end - $proto_start) = $bod;
		print "replacing < $proto > with < $bod >\n";	       
	        $worked |= delta_test ($method, 0);
		$pos += $proto_end - $proto_start;
	    }
	} elsif ($method eq "del_args") {
	    (my $func_name, my $proto_start, my $proto_end, my $func_start, my $func_end) = find_func();
	    if (defined ($func_name) && !defined ($funcs_seen{$func_name})) {
		$funcs_seen{$func_name} = 1;
		if (defined($proto_start)) {
		    my $proto = substr ($prog, $proto_start, $proto_end - $proto_start);
		    die if (!($proto =~ /($RE{balanced}{-parens=>'()'})/));
		    my $proto_args = $1;
		    substr ($proto_args, 0, 1) = "";
		    substr ($proto_args, 0, -1) = "";
		    my @proto_list = split /,/, $proto_args;
		    $pos += $proto_end - $proto_start;
		}
	    }
	} elsif ($method eq "ternary") {
	    my $first = substr($prog, 0, $pos);
	    my $rest = substr($prog, $pos);
	    if ($rest =~ s/^(?<del1>$borderorspc)(?<a>$varnumexp)\s*\?\s*(?<b>$varnumexp)\s*:\s*(?<c>$varnumexp)(?<del2>$borderorspc)/$+{del1}$+{b}$+{del2}/) {
		$prog = $first.$rest;
		my $n1 = "$+{del1}$+{a} ? $+{b} : $+{c}$+{del2}";
		my $n2 = "$+{del1}$+{b}$+{del2}";
		print "replacing $n1 with $n2\n";
		$worked |= delta_test ($method, 0);
	    }	    
	    $first = substr($prog, 0, $pos);
	    $rest = substr($prog, $pos);
	    if ($rest =~ s/^(?<del1>$borderorspc)(?<a>$varnumexp)\s*\?\s*(?<b>$varnumexp)\s*:\s*(?<c>$varnumexp)(?<del2>$borderorspc)/$+{del1}$+{c}$+{del2}/) {
		$prog = $first.$rest;
		my $n1 = "$+{del1}$+{a} ? $+{b} : $+{c}$+{del2}";
		my $n2 = "$+{del1}$+{c}$+{del2}";
		print "replacing $n1 with $n2\n";
		$worked |= delta_test ($method, 0);
	    }	    
	} elsif ($method eq "shorten_ints") {
	    my $first = substr($prog, 0, $pos);
	    my $rest = substr($prog, $pos);
	    if ($rest =~ s/^(?<pref>$borderorspc(\\-|\\+)?(0|(0[xX]))?)(?<del>[0-9a-fA-F])(?<numpart>[0-9a-fA-F]+)(?<suf>[ULul]*$borderorspc)/$+{pref}$+{numpart}$+{suf}/) {
		$prog = $first.$rest;
		my $n1 = "$+{pref}$+{del}$+{numpart}$+{suf}";
		my $n2 = "$+{pref}$+{numpart}$+{suf}";
		print "replacing $n1 with $n2\n";
		$worked |= delta_test ($method, 0);
	    }      
	    $first = substr($prog, 0, $pos);
	    $rest = substr($prog, $pos);
	    my $orig_rest = $rest;
	    if ($rest =~ s/^(?<pref1>$borderorspc)(?<pref2>(\\-|\\+)?(0|(0[xX]))?)(?<numpart>[0-9a-fA-F]+)(?<suf>[ULul]*$borderorspc)/$+{pref1}$+{numpart}$+{suf}/ && ($rest ne $orig_rest)) {
		$prog = $first.$rest;
		my $n1 = "$+{pref1}$+{pref2}$+{numpart}$+{suf}";
		my $n2 = "$+{pref1}$+{numpart}$+{suf}";
		print "replacing $n1 with $n2\n";
		$worked |= delta_test ($method, 0);
	    }     
	    $first = substr($prog, 0, $pos);
	    $rest = substr($prog, $pos);
	    $orig_rest = $rest;
	    if ($rest =~ s/^(?<pref>$borderorspc(\\-|\\+)?(0|(0[xX]))?)(?<numpart>[0-9a-fA-F]+)(?<suf1>[ULul]*)(?<suf2>$borderorspc)/$+{pref}$+{numpart}$+{suf2}/ && ($rest ne $orig_rest)) {
		$prog = $first.$rest;
		my $n1 = "$+{pref}$+{numpart}$+{suf1}$+{suf2}";
		my $n2 = "$+{pref}$+{numpart}$+{suf2}";
		print "replacing $n1 with $n2\n";
		$worked |= delta_test ($method, 0);
	    }      
	} elsif ($method eq "parens") {
	    if (substr($prog, $pos, 1) eq "(") {
		my $p2 = find_match ($pos+1,"(",")");
		if ($p2 != -1) {
		    die if (substr($prog, $pos, 1) ne "(");
		    die if (substr($prog, $p2, 1) ne ")");

		    my $del = substr ($prog, $pos, $p2-$pos+1, "");
		    print "deleting '$del' at $pos--$p2 : ";
		    my $res = delta_test ($method, 0);
		    $worked |= $res;

		    if (!$res) {
			substr ($prog, $p2, 1) = "";
			substr ($prog, $pos, 1) = "";
			print "deleting at $pos--$p2 : ";
			$worked |= delta_test ($method, 0);
		    }
		}
	    }
	} elsif ($method eq "brackets") {
	    if (substr($prog, $pos, 1) eq "{") {
		my $p2 = find_match ($pos+1,"{","}");
		if ($p2 != -1) {
		    die if (substr($prog, $pos, 1) ne "{");
		    die if (substr($prog, $p2, 1) ne "}");

		    my $del = substr ($prog, $pos, $p2-$pos+1, "");
		    print "deleting '$del' at $pos--$p2 : ";
		    my $res = delta_test ($method, 0);
		    $worked |= $res;

		    if (!$res) {
			substr ($prog, $p2, 1) = "";
			substr ($prog, $pos, 1) = "";
			print "deleting at $pos--$p2 : ";
			$worked |= delta_test ($method, 0);
		    }
		}
	    }
	} else {
	    die "unknown reduction method";
	}

	if (!$worked) {
	    $pos++;
	}
    }
}

# invariant: test always succeeds for $cfile.bak

my %all_methods = (

    "all_blanks" => 0,
    "blanks" => 1,
    "crc" => 1,
    "move_func" => 2,
    "del_args" => 2,
    "brackets" => 2,
    "ternary" => 2,
    "parens" => 3,
    "replace_regex" => 4,
    "shorten_ints" => 5,
    "indent" => 15,

    );
 
############################### main #################################

sub usage() {
    print "usage: c_delta.pl test_script.sh file.c [method [method ...]]\n";
    print "available methods are --all or:\n";
    foreach my $method (keys %all_methods) {
	print "  --$method\n";
    }
    die;
}

$test = shift @ARGV;
usage if (!defined($test));
if (!(-x $test)) {
    print "test script '$test' not found, or not executable\n";
    usage();
}

$cfile = shift @ARGV;
usage if (!defined($cfile));
if (!(-e $cfile)) {
    print "'$cfile' not found\n";
    usage();
}

my %methods = ();
usage if (!defined(@ARGV));
foreach my $arg (@ARGV) {
    if ($arg eq "--all") {
	foreach my $method (keys %all_methods) {
	    $methods{$method} = 1;
	}
    } else {
	my $found = 0;
	foreach my $method (keys %all_methods) {
	    if ($arg eq "--$method") {
		$methods{$method} = 1;
		$found = 1;
		last;
	    }
	}
	if (!$found) {
	    print "unknown method '$arg'\n";
	    usage();
	}
    }
}

system "cp $cfile $cfile.orig";
system "cp $cfile $cfile.bak";

sub bymethod {
    return $all_methods{$a} <=> $all_methods{$b};
}

# iterate to global fixpoint

read_file ();    
$orig_prog_len = length ($prog);

while (1) {
    my $success = 0;
    save_copy ("delta_backup_${pass_num}.c");
    foreach my $method (sort bymethod keys %methods) {
	$success |= delta_pass ($method);
    }
    $pass_num++;
    last if (!$success);
}

print "===================== done ====================\n";

print "\n";
print "overall reduction: ";
print_pct();

print "\n";
print "pass statistics:\n";
foreach my $method (sort keys %methods) {
    my $w = $method_worked{$method};
    $w=0 unless defined($w);
    my $f = $method_failed{$method};
    $f=0 unless defined($f);
    print "  method $method worked $w times and failed $f times\n";
}

print "\n";
print "regex statistics:\n";
for (my $n=0; $n<scalar(@regexes_to_replace); $n++) {
    my $a = $regex_worked{$n};
    my $b = $regex_failed{$n};
    next if (($a+$b)==0);
    print "  $n s:$a f:$b\n";
}

print "\n";
print "delimited regex statistics:\n";
for (my $n=0; $n<scalar(@delimited_regexes_to_replace); $n++) {
    my $a = $delimited_regex_worked{$n};
    my $b = $delimited_regex_failed{$n};
    next if (($a+$b)==0);
    print "  $n s:$a f:$b\n";
}

print "\n";
print "there were $cache_hits cache hits\n";

######################################################################