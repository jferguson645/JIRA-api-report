#!/usr/bin/perl

use strict;

use Term::ReadKey;
use Getopt::Long;
use LWP::UserAgent;
use Text::CSV;
use Date::Manip;
use JSON;
use Math::Round;

$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

my ( $project, $theUser, $thePass, $theURL, $points, $done );

GetOptions (
            "proj=s"    => \$project,
            "user=s"    => \$theUser,
            "url=s"     => \$theURL,
            "done=s"    => \$done,
            "pts=s"     => \$points,
            );

unless($project && $theUser && $theURL && $points) {
  usage();
}

unless ($done) {
  $done = "Done";
}

print "\nPlease enter the JIRA password for $theUser: \n";

ReadMode('noecho');
$thePass = ReadLine(0);
chomp($thePass);
ReadMode('normal');

$theURL = &_cleanURL($theURL);

my (%issue_statuses, $time_passed, $theStatuses, $file, @columns, $upper_range, $theData);

my $csv = Text::CSV->new ( { binary => 1 } ) or die "Cannot use CSV: ".Text::CSV->error_diag();

my $initialQuery = "search?jql=project+%3D+". $project ."+AND+status+%3D+". $done ."&fields=key";
my $theQuery = "search?jql=project+%3D+". $project ."+AND+status+%3D+". $done ."&fields=id,key,issuetype,". $points ."&expand=changelog";
my $base_url = "https://". $theURL ."/rest/api/latest/";

my $theIncrement = 0;
my $out_file = $project."-JIRA-data.csv";

print "\nConnecting to [" . $base_url . "] as [" . $theUser . "]...\n";
my $initialData = &_hitTheAPI($base_url, $initialQuery, $theIncrement, $theUser, $thePass);

if($initialData->{'total'} == 0) {
  print "No issues retrieved using \"Done\" status of [".$done."]. Please verify this is the correct status for the project [".$project."].\n\n";
  exit();
}

do {

  $theData = &_hitTheAPI($base_url, $theQuery, $theIncrement, $theUser, $thePass);

  $upper_range = $theIncrement + $theData->{'maxResults'};

  if ( $upper_range > $initialData->{'total'} ) {
    $upper_range = $initialData->{'total'};
  }

  print "\nGetting story data for the [". $project ."] project from JIRA... (". ($theIncrement+1) ." - ". $upper_range ." of ". $initialData->{'total'} ." stories)\n\n";
  &_processData($theData->{'issues'});

  $theIncrement += $theData->{'maxResults'};

}while ( $theIncrement <= $initialData->{'total'} );

print "\nRetrieved ".$upper_range." of ".$initialData->{'total'}." stories.\n";
print "Writing data to ".$out_file.".\n\n";

@columns = &_prepTheFile( $theStatuses );
&_writeData( \%issue_statuses, \@columns );

close $file;

## subroutines below

sub _writeData {
  my ( $theData, $columns ) = @_;

  my %theData = %$theData;
  my @columns = @$columns;
  my $id = shift @columns;
  my ( $value, $row_sum );

  foreach my $key ( keys %theData ) {
    my @row = ($key);
    $row_sum = 0;

    foreach my $column ( @columns ) {
      unless ($column eq "Total Time") {
        unless ($column eq "Points" || $column eq "Card Type") {
          #write in days, not seconds. Always return a positive number.
          $value = nearest(.001,(((abs($theData{$key}{$column}) / 60) / 60) / 24)); 
          $row_sum += $value;
        } else {
          $value = $theData{$key}{$column};
        }
        push @row, $value;
      }
    }

    push @row, $row_sum;
    $csv->print($file, \@row);
    print $file "\n";

  }

}

sub _prepTheFile {
  my ($statuses) = @_;

  my @file_header = ("Card ID", "Card Type", "Points");
  foreach my $status ( keys $statuses ) {
    push @file_header, $status;
  }

  push @file_header, "Total Time";
  open $file, ">:encoding(utf8)", "$out_file" or die "$out_file: $!";
  $csv->column_names (@file_header);
  $csv->print($file, \@file_header);
  print $file "\n";
  return @file_header;
}

sub _hitTheAPI {
  my ( $base_url, $search_query, $increment, $user, $pass ) = @_;

  if($increment != 0 ) {
    $search_query = $search_query . "&startAt=" . ($increment);
  }

  my $browser = LWP::UserAgent->new( protocols_allowed => [ 'https' ] );
  my $request = HTTP::Request->new( GET => $base_url . $search_query );
  $request->authorization_basic( $user, $pass ); 

  my $result = $browser->request( $request );
  my $content = $result->content;
  my $json_content;

  eval { $json_content = decode_json($content); };

  if ($@) {
    print "\nUnable to connect to [".$base_url."] as [".$theUser."] using the provided password.\n\n";
    exit();
  }

  return $json_content;
}

sub _processData {

  my ( $data ) = @_;

  foreach my $issues ($data) {
    foreach my $issue(@$issues) {

      print "Fetching [" . $issue->{'key'} . "]...\n";
      my ($last_fromStatus, $last_toStatus, $last_leftFromTime, $last_enteredToTime, $fromStatus, $toStatus, $leftFromTime, $enteredToTime);

      $issue_statuses{$issue->{'key'}}{'Points'} = $issue->{'fields'}->{$points};
      $issue_statuses{$issue->{'key'}}{'Card Type'} = $issue->{'fields'}->{'issuetype'}->{'name'};

      foreach my $histories($issue->{'changelog'}{'histories'}) {
        foreach my $history(@$histories){
          if ($history->{'items'}['']->{'field'} eq "status" || $history->{'items'}['']->{'field'} eq "resolution") {

            $last_fromStatus = $fromStatus;
            $last_toStatus = $toStatus;
            $last_leftFromTime = $leftFromTime;
            $last_enteredToTime = $enteredToTime;

            $fromStatus = $history->{'items'}['']->{'fromString'};
            $toStatus = $history->{'items'}['']->{'toString'};
            $leftFromTime = $history->{'created'};
            $enteredToTime = $history->{'created'};

            if ($last_toStatus && $last_enteredToTime) {
              my $first_date = UnixDate($enteredToTime,'%s');
              my $second_date = UnixDate($last_enteredToTime, '%s');
              $time_passed = $second_date - $first_date;
              $issue_statuses{$issue->{'key'}}{$toStatus} += $time_passed;
              $theStatuses->{$toStatus} = $toStatus;
              $theStatuses->{$fromStatus} = $fromStatus;
            }
          }
        }
      }
    }
  }
}

sub _cleanURL {

  my ($clean) = @_;

  $clean =~ s!^https?://(?:www\.)?!!i;
  $clean =~ s!/.*!!;
  $clean =~ s/[\?\#\:].*//;

  return $clean;

}

sub usage {
    print @_, "\n", if @_;

    print <<__EOF__;

Exports JIRA Data for a given project into a CSV file.

Usage: perl $0 --user <string> --url <string> --proj <string> --pts <string> --done <string> 

    --user <string>   - Your JIRA username (required)
    --url <string>    - URL of your JIRA instance (required)
    --proj <string>   - Your projects JIRA Project Key (required)
    --pts <string>    - Name of the internal JIRA field that contains story points (required, case sensitive)
    --done <string>   - Name of the "Done" status in JIRA (optional, case sensitive) (Defaults to "Done")

You will be prompted for your JIRA password.

__EOF__

    exit 1;
}

exit();

