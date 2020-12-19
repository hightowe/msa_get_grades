#!/usr/bin/perl

#########################################################################
# Program to pull kids' progress from https://<school>.myschoolapp.com
#########################################################################
#
# Written by Lester Hightower on 03/20/2018
#
# Intended to be used in a cronjob.
# This is the one that I use with Vixie-cron (runs daily, Aug-May):
# 55 5 * 1-5,8-12 * ( echo "<html><body style='font-size: 10px; border:0px solid #0f0f0f;'><pre style='font-size:10px; font-size:1.3vw;'>"; /bin/date; echo; /path/to/bin/MySchoolApp/get_grades.pl; echo "</pre></body></html>" ) | /usr/bin/mutt -e 'set content_type=text/html' -s "Kids' current school grades" parent1.email@foo.com parent2.email@foo.com
#
#########################################################################

# Modules used by this program
use strict;
use File::Spec;			# core
use File::Basename 'fileparse';	#core
use Cwd 'abs_path';		# core
use Data::Dumper;		# core
use JSON::PP;			# core (if need faster, libjson-xs-perl)
use URI;			# liburi-perl
use URI::Escape;		# liburi-perl
use LWP::UserAgent;		# libwww-perl
use IO::Socket::SSL;		# libio-socket-ssl-perl
use HTTP::Request::Common;	# libhttp-message-perl
use HTTP::Cookies;		# libhttp-cookies-perl

# Global settings
my $conf = load_config();
my $urlroot = $conf->{urlroot}; # for syntax convenience

# Global variables
my $DATA = {};                      # Holds the data that we collect
my $ua = get_lwp_ua($conf->{cookies_file}); # Our LWP object
my $json = new JSON::PP;            # Our JSON::PP object

############################################################
# Main program starts here #################################
############################################################

# We use get_webapp_context() to test if we have a valid login...
my $webapp_context = get_webapp_context();
if (! defined($webapp_context)) {
  #print "We need a new login session...\n";
  unlink($conf->{cookies_file});
  login_or_die();
  $webapp_context = get_webapp_context();
} else {
  #print "We have an existing session!\n";
}

my @kids = get_kids_from_webapp_context($webapp_context);
#print &Dumper(\@kids) . "\n";

if (1) {
  GET_LOOP: foreach my $kid (@kids) {
    my $kid_name = $kid->{name};
    $DATA->{$kid_name} = {};
    $DATA->{$kid_name}->{kid} = $kid;
    my $userId = $kid->{userId};
    my $markingPeriodId = $kid->{markingPeriodId} || '';
    my $durationList = 'to be set by code';
    my $schoolYearLabel = 'to be set by code';

    my $url = '';

    # StudentGradeLevelList
    {
      # NOTE: schoolYearLabel can also be pulled from
      # $urlroot/api/webapp/schoolcontext
      $url = $urlroot . "/api/datadirect/StudentGradeLevelList/?studentUserId=$userId";
      my $req = HTTP::Request::Common::GET($url);
      my $response = $ua->request($req);
      if (! $response->is_success) {
        #print $response->as_string(); die;
        die("Failed on GET: $url\n");
      }
      $DATA->{$kid_name}->{StdntGrdLvlLs_json} = $response->decoded_content;
      $DATA->{$kid_name}->{StdntGrdLvlLs} = $json->decode($DATA->{$kid_name}->{StdntGrdLvlLs_json});
      # Pull the current schoolYearLabel if we can
      if (ref($DATA->{$kid_name}->{StdntGrdLvlLs}) eq 'ARRAY') {
        my @data = @{$DATA->{$kid_name}->{StdntGrdLvlLs}};
        #print &Dumper(\@data) . "\n\n";
        StudentGroupTermList: foreach my $dur (@data) {
          if ($dur->{DurationId} > 0 && $dur->{CurrentInd}) {
            $schoolYearLabel = $dur->{SchoolYearSession};
            $DATA->{$kid_name}->{CurrentGradeLevel} = $dur;
            #warn "For $kid_name, set schoolYearLabel=$schoolYearLabel\n";
            last StudentGroupTermList;
          }
        }
      }
    }

    # StudentGroupTermList
    {
      my $uri = URI->new($urlroot . '/api/DataDirect/StudentGroupTermList/');
      $uri->query_form(studentUserId=>$userId,
			schoolYearLabel=>$schoolYearLabel,
			personaId=>1);
      $url = scalar($uri);
      #print $url . "\n";
      my $req = HTTP::Request::Common::GET($url);
      my $response = $ua->request($req);
      if (! $response->is_success) {
        #print $response->as_string(); die;
        die("Failed on GET: $url\n");
      }
      $DATA->{$kid_name}->{StdntGrpTermL_json} = $response->decoded_content;
      $DATA->{$kid_name}->{StdntGrpTermL} = $json->decode($DATA->{$kid_name}->{StdntGrpTermL_json});
      # Pull the current durationId if we can
      if (ref($DATA->{$kid_name}->{StdntGrpTermL}) eq 'ARRAY') {
        my @data = @{$DATA->{$kid_name}->{StdntGrpTermL}};
        #print &Dumper(\@data) . "\n\n";
        StudentGroupTermList: foreach my $dur (@data) {
          if ($dur->{DurationId} > 0 && $dur->{CurrentInd}) {
            $durationList = $dur->{DurationId};
            $DATA->{$kid_name}->{CurrentGroupTerm} = $dur;
            #print "LHHD: for $kid_name, set durationList=$durationList\n";
            last StudentGroupTermList;
          }
        }
      }
    }

    # progress
    {
      my $response = get_progress($userId,$schoolYearLabel,
					$durationList,$markingPeriodId);
      $DATA->{$kid_name}->{progress_json} = $response->decoded_content;
      $DATA->{$kid_name}->{progress} = $json->decode($DATA->{$kid_name}->{progress_json});
    }

    # If needed, find most recent $markingPeriodId. This seems to be imperative
    # only in times of transitions (like Xmas break, between Q2 and Q3), at
    # which time no "current markingPeriodId" is set by get_kids_from_webapp_context().
    # In those circumstances, we pull all marking periods for this kid (here) and
    # choose the largest one (highest int). We then re-pull progress. Note that
    # progress must be pulled first in order to collect the @LeadSectionList.
    #
    # After coding this, I wanted to add the markingPeriodDescription to the output,
    # and that seems to only be retrievable by using this, and so, this code is now
    # used every time (even when $markingPeriodId is pre-defined), but it only re-pulls
    # the progress data when $markingPeriodId was not defined.
    if (ref($DATA->{$kid_name}->{progress}) eq 'ARRAY') {
      if (! length($markingPeriodId)) { $markingPeriodId = 0; }
      my $markingPeriodIdStart = $markingPeriodId;

      # Build the @LeadSectionList from the kid's retrieved progress
      my $arrProg = $DATA->{$kid_name}->{progress};
      my @LeadSectionList = ();
      foreach my $class (@{$arrProg}) {
        if (defined($class->{leadsectionid})) {
          push @LeadSectionList, $class->{leadsectionid};
        }
      }
      #warn "LHHD:\n" . Dumper(\@LeadSectionList) . "\n";

      my %durationSectionList=();
      $durationSectionList{DurationId} = $DATA->{$kid_name}->{CurrentGroupTerm}->{DurationId};

      my @LeadSectionListDS=(); # An array of hashes data structure
      foreach my $leadsectionid (@LeadSectionList) {
        push @LeadSectionListDS, { LeadSectionId => $leadsectionid };
      }
      $durationSectionList{LeadSectionList} = \@LeadSectionListDS;
      my @durationSectionList = (\%durationSectionList); # The data structure needed in the URL
      # print Dumper(\@durationSectionList) . "\n";

      # Pull the GradeBookMyDayMarkingPeriods data
      my $uri_MPs=URI->new($urlroot.'/api/gradebook/GradeBookMyDayMarkingPeriods');
      $uri_MPs->query_form(
		durationSectionList => $json->encode(\@durationSectionList),
		userId=>$userId,
		personaID=>1,
		);
      $url = scalar($uri_MPs);
      #print $url . "\n";
      my $req = HTTP::Request::Common::GET($url);
      my $response = $ua->request($req);
      if (! $response->is_success) {
        #print $response->as_string(); die;
        die("Failed on GET: $url\n");
      }
      my $arrMarkingPeriods = $json->decode($response->decoded_content);
      #print "LHHD: " . Dumper($arrMarkingPeriods) . "\n";

      # Note some case-flipping here (leading M to m)
      MARKING_PERIODS: foreach my $mp (@{$arrMarkingPeriods}) {
        # If we didn't enter this code with a valid markingPeriodId then choose the
        # highest one in this list. If we did, add markingPeriodDescription to $kid
        # for the markingPeriodId that we already knew.
        if ($markingPeriodIdStart == 0 &&
		defined($mp->{MarkingPeriodId}) && $mp->{MarkingPeriodId} > $markingPeriodId) {
          $kid->{markingPeriodId} = $mp->{MarkingPeriodId};
          $markingPeriodId = $kid->{markingPeriodId};
          $kid->{markingPeriodDescription} = $mp->{MarkingPeriodDescription};
        } elsif ($markingPeriodIdStart > 0 && $mp->{MarkingPeriodId} == $markingPeriodIdStart) {
          $kid->{markingPeriodDescription} = $mp->{MarkingPeriodDescription};
          last MARKING_PERIODS;
        }
      }

      # If we started without it and now have a non-zero markingPeriodId, re-pull progress
      if ($markingPeriodIdStart == 0 && $markingPeriodId) {
        warn "Repulling progress for $kid_name due to having to determine the markingPeriodId\n";
        my $response = get_progress($userId,$schoolYearLabel,
					$durationList,$markingPeriodId);
        $DATA->{$kid_name}->{progress_json} = $response->decoded_content;
        $DATA->{$kid_name}->{progress} = $json->decode($DATA->{$kid_name}->{progress_json});
      }
    }

  }
}

#scrub_json($DATA); foreach my $kid (sort keys %{$DATA}) { print "$kid:\n" . &Dumper($DATA->{$kid}) . "\n"; } exit;

KID_OUT: foreach my $kid_name (sort keys %{$DATA}) {
  my $progress = $DATA->{$kid_name}->{progress};
  my $schoollevel = $progress->[0]->{schoollevel};
  my $grade_level = int($DATA->{$kid_name}->{CurrentGradeLevel}->{GradeLevel});
  my $currentterm = $progress->[0]->{currentterm};
  my $markingPeriodDescription = $DATA->{$kid_name}->{kid}->{markingPeriodDescription} || '??';
  my $schoolYear = $DATA->{$kid_name}->{CurrentGradeLevel}->{SchoolYearSession};
  $schoolYear =~ s/ //g; # Change "2020 - 2021" to "2020-2021"

  print "$kid_name ($schoollevel Grade $grade_level, $schoolYear, $currentterm:$markingPeriodDescription):\n";
  foreach my $h (sort { $a->{cumgrade} <=> $b->{cumgrade} } @{$progress}) {
    printf ("  - %6.2f: %-35s %22s\n",
	$h->{cumgrade}, $h->{sectionidentifier}, $h->{groupownername});
  }

  print "\n\n";
}

print "This data was pulled from $urlroot\n";

exit;


############################################################
# Subroutines start here ###################################
############################################################

sub get_lwp_ua($$) {
  my $cookies_file = shift @_;
  my $user_agent = shift @_ || undef;

  my $cookie_jar = HTTP::Cookies->new(
    file     => $cookies_file,
    autosave => 1,
    ignore_discard => 1,
  );
  my $ua = LWP::UserAgent->new(
    cookie_jar => $cookie_jar,
    agent => $user_agent,
    ssl_opts => {
      verify_hostname => 0,
      SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
    },
  );
  return $ua;
}

# Login step
sub login_or_die {
    my $formdata = {
      From => '',
      InterfaceSource => 'WebApp',
      remember => 'false',
      Username => $conf->{uname},
      Password => $conf->{pword},
    };
    my $url = $urlroot . '/api/SignIn';
    my $req = HTTP::Request::Common::POST($url, $formdata);
    my $response = $ua->request($req);
    if (! $response->is_success) {
      # TODO - likely should not die here
      die "Failed POST to login URL: $url";
    }
    my $html_data = $response->decoded_content;
}

sub get_webapp_context() {
  my $url = $urlroot . '/api/webapp/context?_=' . time();
  my $req = HTTP::Request::Common::GET($url);
  my $response = $ua->request($req);
  if (! $response->is_success) {
    return undef;
  }
  my $html = $response->decoded_content;
  my $appcontext = $json->decode($html);
  #print Dumper($appcontext) . "\n\n"; die;
  # If we're logged in, then $appcontext->{UserInfo}->{UserName} eq $conf->{uname}
  if (! (defined($appcontext->{UserInfo}) &&
		defined($appcontext->{UserInfo}->{UserName}) &&
		$appcontext->{UserInfo}->{UserName} eq $conf->{uname})) {
    return undef;
  }
  #print Dumper($appcontext) . "\n\n"; die;
  return($appcontext);
}

# This gets the array of kids from the webapp_context, and
# fills in a couple of keys that are legacy to this code.
sub get_kids_from_webapp_context($) {
  my $webapp_context = shift @_;
  if (! (defined($webapp_context->{Children}) &&
		ref($webapp_context->{Children}) eq 'ARRAY')) {
    return ();
  }
  my @kids = ();
  foreach my $kid_prof (@{$webapp_context->{Children}}) {
    if ($kid_prof->{ParentRoleId} == 1 && $kid_prof->{Id} > 0) {
      $kid_prof->{name} = $kid_prof->{FirstName};
      $kid_prof->{userId} = $kid_prof->{Id};
      push @kids, $kid_prof;
    }
  }
  return @kids;
}

sub scrub_json($) {
  my $data = shift @_;
  foreach my $kid (keys %{$data}) {
    foreach my $key (keys %{$data->{$kid}}) {
      delete($data->{$kid}->{$key}) if ($key =~ m/_json$/);
    }
  }
}

sub load_config() {
  # We expect the *.conf file to be in the same directory
  # with this <program> and named <program>.conf
  my ($name,$path,$suffix) = fileparse(abs_path(__FILE__), qr/\.[^.]*/);
  $path = abs_path($path); # Cleans up any trailing slashes, etc.
  my $conf_path = $path ."/". $name.'.conf';

  # Slurp the config file
  open(my $fh, '<', $conf_path) or die "Can't open config file $conf_path";
  my $conf_content = '';
  read($fh, $conf_content, -s $fh);
  close($fh);

  # Parse the config file
  my %conf = ();
  CONF_LINE: foreach my $line (split(/[\r\n]+/, $conf_content)) {
    if ($line =~ m/^\s*#/) { next CONF_LINE; } # skip comments
    chomp($line);
    if ( my ($k,$v) = $line =~ m/^([^\s]+)\s*=\s*(.+)\s*$/ ) {
      $conf{$k} = $v;
    }
  }

  # Validate the config file
  my @errs = ();
  for my $k ('uname', 'pword', 'cookies_file', 'urlroot') {
    if (! defined($conf{$k})) {
      push @errs, "Required setting \"$k\" missing from config file.";
    }
  }
  if (scalar(@errs) > 0) {
    die "There were fata errors:\n" . join("\n", @errs) . "\n";
  }

  # If cookies_file does not include a path, afix it to our path
  {
    my ($vol,$dirs,$fn) = File::Spec->splitpath( $conf{cookies_file} );
    if (! length($dirs)) {
      $conf{cookies_file} = $path ."/". $conf{cookies_file};
    }
  }

  return \%conf;
}


sub get_progress() {
  my $userId = shift @_;
  my $schoolYearLabel = shift @_;
  my $durationList = shift @_;
  my $markingPeriodId = shift @_;

  my $uri = URI->new($urlroot . '/api/datadirect/ParentStudentUserAcademicGroupsGet');
  $uri->query_form(userId=>$userId,
                   schoolYearLabel=>$schoolYearLabel,
                   memberLevel=>3,
                   persona=>1,
                   durationList=>$durationList,
                   markingPeriodId=>$markingPeriodId,
   ); 
  my $url = scalar($uri);
  #print $url . "\n";
  my $req = HTTP::Request::Common::GET($url);
  my $response = $ua->request($req);
  if (! $response->is_success) {
    #print $response->as_string(); die;
    die("Failed on GET: $url\n");
  }
  return $response;
}

