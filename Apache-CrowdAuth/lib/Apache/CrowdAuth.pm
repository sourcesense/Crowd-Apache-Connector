package Apache::CrowdAuth;

use 5.008000;
use strict;
use warnings;

use Exporter;
use Cache::FileCache;
use Atlassian::Crowd;
use Digest::SHA1  qw(sha1 sha1_hex sha1_base64);
use APR::SockAddr ();


$SOAP::Constants::DO_NOT_USE_XML_PARSER = 1;
 
# Uncomment the following line (and comment out the line below it) to
# enable debug output of the SOAP messages.
#use SOAP::Lite +trace => qw (debug);
use SOAP::Lite;

our @ISA = qw(Exporter);

our $VERSION = '1.2.3';


# Use correct API for loaded version of mod_perl.
#
BEGIN {

    unless ( $INC{'mod_perl.pm'} ) {

        my $class = 'mod_perl';

        if ( exists $ENV{MOD_PERL_API_VERSION} && $ENV{MOD_PERL_API_VERSION} == 2 ) {
            $class = 'mod_perl2';
        }

        eval "require $class";
    }

    my @import = qw( OK HTTP_UNAUTHORIZED SERVER_ERROR );

    if ( $mod_perl::VERSION >= 1.999022 ) { # mod_perl 2.0.0 RC5
        require Apache2::RequestRec;
        require Apache2::RequestUtil;
        require Apache2::RequestIO;
        require Apache2::Log;
        require Apache2::Connection;
        require Apache2::Const;
        require Apache2::Access;
        Apache2::Const->import(@import);
     }
     elsif ( $mod_perl::VERSION >= 1.99 ) {
        require Apache::RequestRec;
        require Apache::RequestUtil;
        require Apache::RequestIO;
        require Apache::Log;
        require Apache::Connection;
        require Apache::Const;
        require Apache::Access;
        Apache::Const->import(@import);
    }
    else {
        require Apache;
        require Apache::Log;
        require Apache::Constants;
        Apache::Constants->import(@import);
    }
}

use constant MP2 => $mod_perl::VERSION >= 1.999022 ? 1 : 0;

# ---------------------------------------------------------------------------

# Create the cache 
sub init_cache($) {
	my $r = shift;
	
	my $cache;
	
	my $cache_location = $r->dir_config('CrowdCacheLocation');
	
	if(!defined $cache_location) {
		# use default location $TEMP/FileCache
		$cache = new Cache::FileCache( { namespace => $r->auth_name()} );
	} else {
		$cache = new Cache::FileCache( { cache_root => $cache_location,
											namespace => $r->auth_name()} );
	}	

	return $cache;	
}

# ---------------------------------------------------------------------------

sub read_options($) {
	my $r = shift;
	my $rlog = $r->log;

	# Get parameters from the apache conf file
	my $login_page= $r->dir_config('CrowdLoginPage');
	my $useproxy = $r->dir_config('CrowdUseProxy');
	my $app_name = $r->dir_config('CrowdAppName');
	my $app_credential = $r->dir_config('CrowdAppPassword');
	my $cache_enabled = $r->dir_config('CrowdCacheEnabled') || 'on';
	my $cache_expiry = $r->dir_config('CrowdCacheExpiry') || '300';
	$cache_expiry = $cache_expiry.' seconds';
	my $soaphost = $r->dir_config('CrowdSOAPURL') || "http://localhost:8095/crowd/services/SecurityServer";
	
	my $disable_parser = $r->dir_config('CrowdUseInternalXMLParser') || 'yes';
	
	# By default, SOAP::Lite uses XML::Parser, which uses libexpat, which can
	# conflict with some apache builds and cause segfaults. This option tells
	# SOAP::Lite to use an internal pure-perl parser
	if(defined($disable_parser) && ($disable_parser eq 'yes')) {
		$SOAP::Constants::DO_NOT_USE_XML_PARSER = 1;
	}
	
	return ($app_name, $app_credential, $cache_enabled, $cache_expiry, $soaphost,$login_page,$useproxy);
}	

# ---------------------------------------------------------------------------

sub get_app_token($$$$$$) {
	my ($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry) = @_; 
	
	my $apptoken;
	my $rlog = $r->log;
	
	if(defined $cache) {
		$apptoken = $cache->get($app_name.'___APP');
	}  
		
	if(!defined $apptoken) {
		$apptoken = Atlassian::Crowd::authenticate_app($soaphost, $app_name, $app_credential);
		
		if((defined $cache) && (defined $apptoken)) {
			$rlog->debug('CrowdAuth: app token cache miss!...');
			
			# purge whenever we re-auth the app to clear out expired entries
			$cache->purge();
			$cache->set($app_name.'___APP', $apptoken, $cache_expiry);
		}
		
	} else {
		$rlog->debug('CrowdAuth: app token cache hit!...'.$apptoken);
	}
		
	return $apptoken;
}

sub trim
{
   my $string = shift;
   $string =~ s/^\s+//;
   $string =~ s/\s+$//;
   return $string;
}


# ---------------------------------------------------------------------------

# Entry Point
#
sub handler {
	my $r = shift;
	
	my $userAgent = $r->headers_in->{'User-Agent'} || '';
	
	my $c = $r->connection;

	my $remoteAddress = $c->remote_addr()->ip_get;
	
	my $base_server = "127.0.0.1";
	
	my $rlog = $r->log;

 	my $cookie = $r->headers_in->{Cookie} || '';

 	my @cookies = split(/;/,$cookie);
 	my $token;
 	foreach my $singlecookie (@cookies) {
     	my @cookieval = split(/=/,$singlecookie); 
     	my $cookiename =  trim($cookieval[0]);
     	if($cookiename eq "crowd.token_key") {
     		$token = trim($cookieval[1]);
     	}
 	}
	
	my ($app_name, $app_credential, $cache_enabled, $cache_expiry, $soaphost, $login_page, $useproxy) = read_options($r); 
	
	my $cache;
	if($cache_enabled eq 'on') {
        # Initialise the cache
        $cache = init_cache($r);
    }
    
	my $apptoken = get_app_token($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry);

	my $isValid;
	if(defined $token) {   
		$isValid = Atlassian::Crowd::isValidPrincipalToken($soaphost,$app_name,$apptoken,$token,$userAgent,$remoteAddress,$base_server,$useproxy);
	}

	if(!defined $isValid) {
		$r->status(302);
     	$r->headers_out->add('Location' => $login_page);
     	$r->headers_out->add('Cache-Control' => 'no-cache,no-store');
     	$r->headers_out->add('Pragma' => 'no-cache');
	}
	
	return OK;
}


# ---------------------------------------------------------------------------



1;
__END__


=head1 NAME

Apache::CrowdAuth rev. /revision/ - Apache authentication handler that uses Atlassian Crowd.

=head1 SYNOPSIS

<Location /location>
  AuthName crowd
  AuthType Basic

  PerlAuthenHandler Apache::CrowdAuth
  PerlSetVar CrowdAppName appname
  PerlSetVar CrowdAppPassword apppassword
  PerlSetVar CrowdSOAPURL http://localhost:8095/crowd/services/SecurityServer
  PerlSetVar CrowdCacheEnabled on
  PerlSetVar CrowdCacheLocation /tmp/CrowdAuthCache
  PerlSetVar CrowdCacheExpiry 300

  require valid-user
</Location>

=head1 DESCRIPTION

This Module allows you to configure Apache to use Atlassian Crowd to 
handle basic authentication.
	
See http://confluence.atlassian.com/x/rgGY

for full documentation.

=head2 EXPORT

None by default.



=head1 SEE ALSO

http://www.atlassian.com/crowd

=head1 AUTHOR

Atlassian. Changed by Gustavo Nalle Fernandes (g.fernandes@sourcesense.com)

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Atlassian

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.

=cut
