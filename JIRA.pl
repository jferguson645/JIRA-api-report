#!/usr/bin/perl

use strict;

use Term::ReadKey;
use Getopt::Long;
use LWP::UserAgent;
use Text::CSV;
use Date::Manip;
use JSON;

$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

my ( $project, $theUser, $thePass, $theURL, $done, $points );

GetOptions (
            "proj=s"    => \$project,
            "user=s"    => \$theUser,
            "url=s"     => \$theURL,
            "done=s"    => \$done,
            "pts=s"     => \$points,
            );

unless($project && $theUser && $theURL && $done && $points) {
	usage();
}

print "Please enter the JIRA password for $theUser: \n";

ReadMode('noecho');
$thePass = ReadLine(0);
chomp($thePass);
ReadMode('normal');

$base_url = &clean_url($base_url);

my (%issue_statuses, $time_passed, $theStatuses, $file, @columns, $upper_range, $theData);

my $csv = Text::CSV->new ( { binary => 1 } ) or die "Cannot use CSV: ".Text::CSV->error_diag();

my $initialQuery = "search?jql=project+%3D+". $project ."+AND+status+%3D+". $done ."&fields=key";
my $theQuery = "search?jql=project+%3D+". $project ."+AND+status+%3D+". $done ."&fields=id,key,". $points ."&expand=changelog";
my $base_url = "https://". $theURL ."/rest/api/latest/";

my $theIncrement = 0;
my $out_file = "JIRA-".$project."-data.csv";

print "Connecting to " . $base_url . " as " . $theUser . "...\n";

my $initialData = &hitTheAPI($base_url, $initialQuery, $theIncrement, $theUser, $thePass);

do {

	$theData = &hitTheAPI($base_url, $theQuery, $theIncrement, $theUser, $thePass);

	$upper_range = $theIncrement + $theData->{'maxResults'};

	if ( $upper_range > $initialData->{'total'} ) {
		$upper_range = $initialData->{'total'}
	}

	print "Getting completed story data for (". $project .") from JIRA... (". ($theIncrement+1) ." - ". $upper_range ." of ". $initialData->{'total'} .")\n";
	&processData($theData->{'issues'});

	$theIncrement += $theData->{'maxResults'};

}while ( $theIncrement <= $initialData->{'total'} );

@columns = &prepTheFile( $theStatuses );
&writeData( \%issue_statuses, \@columns );

close $file;

## subroutines below

sub writeData {
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
				unless ($column eq "Points") {
					$value = $theData{$key}{$column} / 60 #write in minutes, not seconds;
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

sub prepTheFile {
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

sub hitTheAPI {
	my ( $base_url, $search_query, $increment, $user, $pass ) = @_;

	#modify search query if increment is not 0
	if($increment > 0 ) {
		$search_query = $search_query . "&startAt=" . ($increment);
	}

	my $browser = LWP::UserAgent->new( protocols_allowed => [ 'https' ] );
	my $request = HTTP::Request->new( GET => $base_url . $search_query );
	$request->authorization_basic( $user, $pass ); 
	my $result = $browser->request( $request );
	my $content = $result->content;

	my $json_content = decode_json($content);

	return $json_content;
}

sub processData {

	my ( $data ) = @_;

	foreach my $issues ($data) {
		foreach my $issue(@$issues) {

			print "Fetching " . $issue->{'key'} . "...\n";
			my ($last_fromStatus, $last_toStatus, $last_leftFromTime, $last_enteredToTime, $fromStatus, $toStatus, $leftFromTime, $enteredToTime);

			$issue_statuses{$issue->{'key'}}{'Points'} = $issue->{'fields'}->{$points};

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

sub clean_url {

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
Usage: $0 --user <string> --url <string> --proj <string> --done <string> --pts <string>
    --user <string>   - JIRA username (required)
    --url <string>    - JIRA URL (required)
    --proj <string>   - JIRA Project Identifier (required)
    --done <string>   - "Done" status in JIRA (required, case sensitive)
    --pts <string>    - JIRA field that contains your story points (required)
You will be prompted for your JIRA password.
__EOF__

    exit 1;
}

exit();