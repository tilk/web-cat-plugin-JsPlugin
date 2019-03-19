#!/usr/bin/perl -w
#=============================================================================
#   @(#)$Id$
#-----------------------------------------------------------------------------
#   Web-CAT Grader: plug-in for JavaScript submissions
#=============================================================================

use strict;
use Config::Properties::Simple;
#use File::Basename;
#use File::Copy;
#use File::stat;
use Proc::Background;
#use Web_CAT::Beautifier;    ## Soon, I hope. -sb
use Web_CAT::FeedbackGenerator;
use Web_CAT::Utilities
    qw(copyHere confirmExists addReportFileWithStyle);

#=============================================================================
# Bring command line args into local variables for easy reference
#=============================================================================

my $propfile     = $ARGV[0];   # property file name
my $cfg          = Config::Properties::Simple->new(file => $propfile);

my $localFiles   = $cfg->getProperty('localFiles', '');
my $resultDir    = $cfg->getProperty('resultDir'     );
my $pluginHome   = $cfg->getProperty('pluginHome'    );
my $workingDir   = $cfg->getProperty('workingDir'    );
my $timeout      = $cfg->getProperty('timeout', 30   );

my $debug        = $cfg->getProperty('debug',      0 );
my $hintsLimit   = $cfg->getProperty('hintsLimit', 3 );
my $node         = $cfg->getProperty('nodeCmd', 'node');
my $nodeModules  = $cfg->getProperty('nodeModules');
my $instrTest    = $cfg->getProperty('instructorUnitTest');
my $scriptData   = $cfg->getProperty('scriptData', '.');
my $max_score    = $cfg->getProperty('max.score.correctness', 0 );

#-------------------------------------------------------
#   Local file location definitions within this script
#-------------------------------------------------------

my @beautifierIgnoreFiles = ();

my $scriptLog_relative      = "script.log";
my $scriptLog               = File::Spec->join($resultDir, $scriptLog_relative);

my $instrOutput_relative    = "instructor-unittest-out.txt";
my $instrOutput             = File::Spec->join($resultDir, $instrOutput_relative);

my $instrReport_relative    = "instructor-unittest-report.html";
my $instrReport             = File::Spec->join($resultDir, $instrReport_relative);

#=============================================================================
# Script startup
#=============================================================================
#   Change to specified working directory
chdir($workingDir);
print "working dir set to $workingDir\n" if $debug;

$ENV{'NODE_PATH'} = $nodeModules;

#-------------------------------------------------------
# Path manipulation utilities
#-------------------------------------------------------

sub dirOf {
    my $path = shift;
    my ($volume, $directories, $file) = File::Spec->splitpath($path);
    return File::Spec->catpath($volume, $directories, '');
}

sub fileOf {
    my $path = shift;
    my ($volume, $directories, $file) = File::Spec->splitpath($path);
    return $file;
}

#-------------------------------------------------------
# Simple logging facility
#-------------------------------------------------------

sub adminLog
{
    open(SCRIPTLOG, ">>$scriptLog") ||
        die "Cannot open file for output '$scriptLog': $!";
    print SCRIPTLOG join("\n", @_), "\n";
    close(SCRIPTLOG);
}

#-------------------------------------------------------
# Reporting errors back to student
#-------------------------------------------------------

my $expSectionId = 0;

sub reportError
{
    my $rpt_absolute_path = shift;
    my $rpt_relative_path = shift;
    my $rpt_title         = shift;
    my $rpt_message       = shift;

    my $errorFeedbackGenerator =
        new Web_CAT::FeedbackGenerator($rpt_absolute_path);
    $errorFeedbackGenerator->startFeedbackSection(
        $rpt_title,
        ++$expSectionId,
        0);
    $errorFeedbackGenerator->print($rpt_message);
    $errorFeedbackGenerator->endFeedbackSection;

    # Close down this report
    $errorFeedbackGenerator->close;
    addReportFileWithStyle($cfg, $rpt_relative_path, 'text/html', 1);
}

#-------------------------------------------------------
# HTML escaping
#-------------------------------------------------------

sub htmlEscape
{
    my $str = shift;
    $str = Web_CAT::HTML::Entities::encode_entities($str, "<>&");
    return $str;
}

#-------------------------------------------------------
# Locate instructor unit test implementation
#-------------------------------------------------------

$scriptData =~ s,/$,,;

if (!defined($instrTest))
{
    die "Instructor unit test not defined.";
}

my $instrTestName = fileOf($instrTest);

my $instrSrc = confirmExists($scriptData, $instrTest);
print "instrSrc = $instrSrc\n" if $debug;

if (-f $instrSrc)
{
    print "Instructor unit test is a file\n" if $debug;
    copyHere($instrSrc, dirOf($instrSrc), \@beautifierIgnoreFiles);
}
else
{
    die "Instructor unit test is not a file.";
}

#-------------------------------------------------------
# Copy over input/output data files as necessary
#-------------------------------------------------------

if (defined $localFiles && $localFiles ne "")
{
    my $lf = confirmExists($scriptData, $localFiles);
    print "localFiles = $lf\n" if $debug;
    if (-d $lf)
    {
        print "localFiles is a directory\n" if $debug;
        copyHere($lf, $lf, \@beautifierIgnoreFiles);
    }
    else
    {
        print "localFiles is a single file\n" if $debug;
        copyHere($lf, dirOf($lf), \@beautifierIgnoreFiles);
    }
}

#-------------------------------------------------------
# Create jest.config.js
#-------------------------------------------------------

open(JESTCONFIG, "> jest.config.js");

print JESTCONFIG <<EOF;
module.exports = {
    verbose: true,
    bail: $hintsLimit,
    globals: {
        filename: 'toplevel.sv'
    },
};
EOF

close(JESTCONFIG);

#=============================================================================
# Execute the test suite and collect results
#=============================================================================

my $score = 1.0;

sub run_test {
    my $testfile  = shift;
    my $outfile   = shift;
	my $report    = shift;
	my $reportRel = shift;

    my $cmdline = $Web_CAT::Utilities::SHELL
        . "$node $nodeModules/.bin/jest $testfile --color=false > /dev/null 2> $outfile";

    print "cmdline = ", $cmdline, "\n" if $debug;

    # Exec program and collect output
    my ($exitcode, $timeout_status) =
        Proc::Background::timeout_system($timeout, $cmdline);
    $exitcode = $exitcode>>8;    # Std UNIX exit code extraction.
    print "exitcode = $exitcode, timeout_status = $timeout_status\n" if $debug;

    if ($timeout_status) {
        adminLog("Script thinks that a timeout happened.\n" .
            "Timeout value = $timeout\n");
		reportError($report, $reportRel, "Test Error Report",
			"<p><b class=\"warn\">Testing your solution exceeded the "
			. "allowable time limit for this assignment.</b></p>");
        return 0;
    }

    open(TEST_OUTPUT, "$outfile") ||
        die "Cannot open file for input '$outfile': $!";

    my $valid = 0;
    my $currentFile;
    my $total = 0;
    my $passed = 0;
    my $failedRequired = 0;
    my @failedTests;

    while (<TEST_OUTPUT>)
    {
        chomp;

        if (m/^(PASS|FAIL) (.*)$/o) {
            print "Parsing results of $2\n" if $debug;
            $valid = 1;
            $currentFile = $2;
        }
        elsif (m/^Tests:[ ]*(?:([0-9]+) failed, )?(?:([0-9]+) passed, )?([0-9]+) total/o) {
            $passed = defined $2 ? $2 : 0;
            $total = $3;
            print "$passed passed, $total total\n" if $debug;
        }
        elsif (m/^[ ]+● (.*)$/o) {
            push(@failedTests, $1) if (@failedTests < $hintsLimit);
            if (m/REQUIRED/o) {
                $failedRequired = 1;
            }
        }

    }

    close(TEST_OUTPUT);

    if (!$valid) {
        adminLog("Results were not parsed correctly.\n");
		reportError($report, $reportRel, "Test Error Report",
			"<p><b class=\"warn\">Test suite results were not correctly formatted."
			. "Please report this to the instructor.</b></p>");
        return 0;
    }

    my $result = $failedRequired ? 0 : ($total > 0) ? $passed / ($total * 1.0) : 0;

	my $feedbackGenerator = new Web_CAT::FeedbackGenerator($report);

    $feedbackGenerator->startFeedbackSection(
        "Test results",
        ++$expSectionId,
        $result == 1 ? 1 : 0);
    
    $feedbackGenerator->print("<p>Summary: $passed passed, $total total</p>\n");

    if (@failedTests) {
        $feedbackGenerator->print("<p>Failed tests:</p><ul>");
        foreach (@failedTests) {
            $feedbackGenerator->print("<li>" . htmlEscape($_) . "</li>");
        }
        $feedbackGenerator->print("</ul>");
    }
    
    $feedbackGenerator->endFeedbackSection;
    $feedbackGenerator->close;
    addReportFileWithStyle($cfg, $reportRel, 'text/html', 1);

    return $result;
}

$score = run_test($instrTestName, $instrOutput, $instrReport, $instrReport_relative);

#=============================================================================
# Update and rewrite properties to reflect status
#=============================================================================

$cfg->setProperty('score.correctness', $score * $max_score);
$cfg->save();

if ( $debug )
{
    my $props = $cfg->getProperties();
    while ( ( my $key, my $value ) = each %{$props} )
    {
        print $key, " => ", $value, "\n";
    }
}

