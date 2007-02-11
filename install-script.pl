#!/usr/local/bin/perl
# Installs a new script into a virtual server

package virtual_server;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/install-script.pl";
require './virtual-server-lib.pl';
$< == 0 || die "install-script.pl must be run as root";
&foreign_require("mailboxes", "mailboxes-lib.pl");
&set_all_text_print();

# Parse command-line args
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--domain") {
		$domain = shift(@ARGV);
		}
	elsif ($a eq "--type") {
		$sname = shift(@ARGV);
		}
	elsif ($a eq "--version") {
		$ver = shift(@ARGV);
		}
	elsif ($a eq "--path") {
		$opts->{'path'} = shift(@ARGV);
		$opts->{'path'} =~ /^\/\S*$/ ||&usage("Path must start with /");
		}
	elsif ($a eq "--force-dir") {
		$forcedir = shift(@ARGV);
		$forcedir =~ /^\/\S*$/ ||&usage("Forced directory must start with /");
		}
	elsif ($a eq "--db") {
		$dbtype = shift(@ARGV);
		if ($dbtype =~ /^(\S+)\s+(\S+)$/) {
			$dbtype = $1;
			$dbname = $2;
			}
		else {
			$dbname = shift(@ARGV);
			}
		&indexof($dbtype, @all_database_types) >= 0 ||
			&usage("$dbtype is not a valid database type. Allowed types are : ".join(" ", @all_database_types));
		$dbname =~ /^\S+$/ ||
			&usage("Missing or invalid database name");
		$opts->{'db'} = $dbtype."_".$dbname;
		}
	elsif ($a eq "--newdb") {
		$opts->{'newdb'} = 1;
		}
	elsif ($a eq "--opt") {
		$oname = shift(@ARGV);
		if ($oname =~ /^(\S+)\s+(\S+)$/) {
			$oname = $1;
			$ovalue = $2;
			}
		else {
			$ovalue = shift(@ARGV);
			}
		$opts->{$oname} = $ovalue;
		}
	elsif ($a eq "--upgrade") {
		$id = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Validate args
$domain && $sname || &usage();
$d = &get_domain_by("dom", $domain);
$d || usage("Virtual server $domain does not exist");
$script = &get_script($sname);
$script || &usage("Script type $sname is not known");
$ver || &usage("Missing version number. Available versions are : ".
	       join(" ", @{$script->{'versions'}}));
if ($ver eq "latest") {
	$ver = $script->{'versions'}->[0];
	}
else {
	&indexof($ver, @{$script->{'versions'}}) >= 0 ||
	       &usage("Version $ver is not valid for script. ".
		      "Available versions are : ".
		      join(" ", @{$script->{'versions'}}));
	}
if ($id) {
	# Find script being upgraded
	@scripts = &list_domain_scripts($d);
	($sinfo) = grep { $_->{'id'} eq $id } @scripts;
	$sinfo || &usage("No script install to upgrade with ID $id was found");
	$opts = $sinfo->{'opts'};
	}

# Check domain features
$d->{'web'} && $d->{'dir'} ||
	&usage("Scripts can only be installed into virtual servers with a ".
	       "website and home directory");

# Validate options
if ($opts->{'path'}) {
	# Convert the path into a directory
	if ($forcedir) {
		# Explicitly set by user
		$opts->{'dir'} = $forcedir;
		}
	else {
		# Work out from path
		$perr = &validate_script_path($opts, $script, $d);
		&usage($perr) if ($perr);
		}
	}
if ($opts->{'db'}) {
	($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
	@dbs = &domain_databases($d);
	($db) = grep { $_->{'type'} eq $dbtype &&
		       $_->{'name'} eq $dbname } @dbs;
	if (!$opts->{'newdb'}) {
		$db || &usage("$dbtype database $dbname does not exist");
		}
	else {
		$db && &usage("$dbtype database $dbname already exists");
		}
	}
if (defined(&{$script->{'check_func'}}) && !$sinfo) {
	$oerr = &{$script->{'check_func'}}($d, $ver, $opts, $sinfo);
	if ($oerr) {
		&usage("Options problem detected : $oerr");
		}
	}

# Check dependencies
&$first_print("Checking dependencies ..");
$derr = &{$script->{'depends_func'}}($d, $ver);
if ($derr) {
	&$second_print(".. failed : $derr");
	exit(1);
	}
else {
	&$second_print(".. done");
	}

# Check PHP version
$phpvfunc = $script->{'php_vers_func'};
if (defined(&$phpvfunc)) {
	&$first_print("Checking PHP version ..");
	@vers = &$phpvfunc($d, $ver);
	$phpver = &setup_php_version($d, \@vers, $opts->{'path'});
	if (!$phpver) {
		&$second_print(".. version ",join(" ", @vers),
			       " of PHP is required, but not available");
		exit(1);
		}
	else {
		&$second_print(".. done");
		}
	}

# First fetch needed files
&$first_print("Fetching required files ..");
$ferr = &fetch_script_files($d, $ver, $opts, $sinfo, \%gotfiles, 1);
if ($ferr) {
	&$second_print(".. failed : $ferr");
	exit(1);
	}
else {
	&$second_print(".. done");
	}

# Install needed PHP modules
if (!&setup_php_modules($d, $script, $ver, $phpver)) {
	exit(1);
	}
if (!&setup_pear_modules($d, $script, $ver, $phpver)) {
	exit(1);
	}

# Call the install function
&$first_print(&text('scripts_installing', $script->{'desc'}, $ver));
($ok, $msg, $desc, $url) = &{$script->{'install_func'}}($d, $ver, $opts, \%gotfiles, $sinfo);
if ($msg =~ /</) {
	$msg = &mailboxes::html_to_text($msg);
	$msg =~ s/^\s+//;
	$msg =~ s/\s+$//;
	}
print "$msg\n";

if ($ok) {
	&$second_print($text{'setup_done'});

	# Record script install in domain
	if ($sinfo) {
		&remove_domain_script($d, $sinfo);
		}
	&add_domain_script($d, $sname, $ver, $opts, $desc, $url);

	# Config web server for PHP
	if (&indexof("php", @{$script->{'uses'}}) >= 0) {
		&$first_print($text{'scripts_apache'});
		if (&setup_web_for_php($d, $script)) {
			&$second_print($text{'setup_done'});
			&restart_apache();
			}
		else {
			&$second_print($text{'scripts_aalready'});
			}
		}
	}
else {
	&$second_print($text{'scripts_failed'});
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Installs a third-party script into some virtual server.\n";
print "\n";
print "usage: install-script.pl --domain domain.name\n";
print "                         --type name\n";
print "                         --version number|\"latest\"\n";
print "                         [--path url-path]\n";
print "                         [--db type name]\n";
print "                         [--opt name value]\n";
print "                         [--upgrade id]\n";
print "                         [--force-dir directory]\n";
exit(1);
}

