package Plugins::SqueezeCloud::Oauth2;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by Daniel Vijge
#
# See file LICENSE for full license details

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS::VersionOneAndTwo;
use Digest::SHA qw(sha256_base64);

my $log   = logger('plugin.squeezecloud');
my $prefs = preferences('plugin.squeezecloud');
my $cache = Slim::Utils::Cache->new();

use constant CLIENT_ID => "112d35211af80d72c8ff470ab66400d8";
use constant CLIENT_SECRET => "fc63200fee37d02bc3216cfeffe5f5ae";
use constant REDIRECT_URI => "https%3A%2F%2Fdanielvijge.github.io%2FSqueezeCloud%2Fcallback.html";
use constant META_CACHE_TTL => 86400 * 30; # 24 hours x 30 = 30 days

sub isLoggedIn {
  return(isRefreshTokenAvailable() || isApiKeyAvailable());
}

sub isApiKeyAvailable {
   return ($prefs->get('apiKey') ne '');
}

sub isAccessTokenAvailable {
  return ($cache->get('access_token') ne '');
}

sub isRefreshTokenAvailable {
  return ($cache->get('refresh_token') ne '');
}

sub isAccessTokenExpired {
  return 0 if isApiKeyAvailable();       # API key cannot expire
  return 0 if isAccessTokenAvailable();  # Access token still valid
  return 1 if isRefreshTokenAvailable(); # Access token expired, refresh token available
  return 1;                              # This should not happen, equal to isLoggedIn() == false
}

sub getAccessToken {
  $log->debug('getAccessToken started.');

  if (!isRefreshTokenAvailable()) {
    $log->error('No authentication available. Use the settings page to log in first.');
    return;
  }

  if (!isAccessTokenAvailable()) {
    $log->info('Access token has expired. Getting a new access token with the refresh token.');
    getAccessTokenWithRefreshToken(\&getAccessToken, @_);
    return;
  }
  
  $log->debug('Cached access token ' . $cache->get('access_token'));
  return $cache->get('access_token');
}

sub getAuthorizationToken {
  $log->debug('getAuthorizationToken started.');

  my $cb = shift;
  my ($class, $client, $params, $callback, @args) = @_;

  if (!$cache->get('codeVerifier')) {
    $log->error('No code verifier is available. Reload the page and try to authenticate again.');
    return;
  }

  my $post = "grant_type=authorization_code" .
    "&client_id=" . CLIENT_ID .
    "&client_secret=" . CLIENT_SECRET .
    "&redirect_uri=" . REDIRECT_URI .
    "&code_verifier=" . $cache->get('codeVerifier') .
    "&code=" . $params->{code};

  my $http = Slim::Networking::SimpleAsyncHTTP->new(
    sub {
      $log->debug('Successful request for authorization_code.');
      my $response = shift;
      my $result = eval { from_json($response->content) };
      
      $cache->set('access_token', $result->{access_token}, $result->{expires_in} - 60);
      $cache->set('refresh_token', $result->{refresh_token}, META_CACHE_TTL);
      delete $params->{code};
      $cb->($class, $client, $params, $callback, @args) if $cb;
    },
    sub {
      $log->error('Failed request for authorization_code.');
      $log->error($_[1]);

      my $response = shift;
      my $result = eval { from_json($response->content) };
      $log->error($result);
    },
    {
      timeout => 15,
    }
  );
  $log->debug($post);
  $http->post(
    "https://secure.soundcloud.com/oauth/token",
    'Content-Type' => 'application/x-www-form-urlencoded',
    $post,
  );
}

sub getAccessTokenWithRefreshToken {
  $log->debug('getAccessTokenWithRefreshToken started.');

  my $cb  = shift;
  my @params = @_;

  if (!isRefreshTokenAvailable()) {
    $log->error('No authentication available. Use the settings page to log in first.');
    return;
  }

  if (isAccessTokenAvailable()) {
    $log->debug('Still an access token available. No need for a refresh.');
    return;
  }

  $log->debug('Cached refresh token ' . $cache->get('refresh_token'));
  my $post = "grant_type=refresh_token" .
    "&client_id=" . CLIENT_ID .
    "&client_secret=" . CLIENT_SECRET .
    "&refresh_token=" . $cache->get('refresh_token');

  my $http = Slim::Networking::SimpleAsyncHTTP->new(
    sub {
      $log->debug('Successful request for refresh_token');
      my $response = shift;
      my $result = eval { from_json($response->content) };
      $cache->set('access_token', $result->{access_token}, $result->{expires_in} - 60);
      $cache->set('refresh_token', $result->{refresh_token}, META_CACHE_TTL);
      $cb->(@params) if $cb;
    },
    sub {
      $log->error('Failed request for refresh_token');
      $log->error($_[1]);
      $log->debug('Removing refresh_token for failed request. User is nog logged out.');
      $cache->remove('refresh_token');
      $cb->(@params) if $cb;
    },
    {
      timeout => 15,
    }
  );
  $log->debug($post);
  $http->post(
    "https://secure.soundcloud.com/oauth/token",
    'Content-Type' => 'application/x-www-form-urlencoded',
    $post,
  );
}

sub getAuthenticationHeaders {
  $log->debug('getAuthenticationHeaders started.');
  if (isApiKeyAvailable()) {
    # If there is still an older API key, use this for authentication
    $log->debug('Using old API key ' . $prefs->get('apiKey'));
    return 'Authorization' => 'OAuth ' . $prefs->get('apiKey');
  }
  else {
    $log->debug('Using bearer token for authorization');
    return 'Authorization' => 'Bearer ' . getAccessToken();
  }
}

# This function generates random strings of a given length
# Copied from  Slim::Player::Squeezebox, but for some reason it cannot
# be called directly.
sub generate_random_string
{
	# the length of the random string to generate
	my $length_of_randomstring = shift;

	my @chars = ('a'..'z','A'..'Z','0'..'9','_');
	my $random_string;

	foreach (1..$length_of_randomstring) {
		#rand @chars will generate a random number between 0 and scalar @chars
		$random_string .= $chars[rand @chars];
	}

	return $random_string;
}

sub getCodeChallenge {
  $log->debug('getCodeChallenge started.');
  if ($cache->get('codeChallenge')) {
    $log->debug('Random string [cached]: '. $cache->get('codeVerifier'));
    $log->debug('S256 [cached]: '.$cache->get('codeChallenge'));
    return $cache->get('codeChallenge');
  }

	my $randomString = generate_random_string(56);
	my $s256 = sha256_base64($randomString);
	# the code challange should be URL-safe, so some characters need to be replaced:
	# + => -
	# / -> _
	# trim trailing =
	$s256 =~ s/\+/-/g;
	$s256 =~ s/\//_/g;
	$s256 =~ s/=$//g;

	$log->debug('Random string: '.$randomString);
	$log->debug('S256: '.$s256);

	# user must complete the authorization flow within 5  minutes after getting the code
	# from SoundCloud, otherwise the cached code verifier is no longer available.
	# A code generated by SoundCloud only seems to be valid for some time.
	$cache->set('codeVerifier', $randomString, 300);
	$cache->set('codeChallenge', $s256, 300);
  return $s256;
}

1;
