package Plugins::SqueezeCloud::Settings;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by David Blackman (first release),
#   Robert Gibbon (improvements),
#   Daniel Vijge (improvements),
#   Robert Siebert (improvements),
# See file LICENSE for full license details

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;

use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.squeezecloud');
my $prefs = preferences('plugin.squeezecloud');
my $cache = Slim::Utils::Cache->new('squeezecloud');

# Returns the name of the plugin. The real
# string is specified in the strings.txt file.
sub name {
	return 'PLUGIN_SQUEEZECLOUD';
}

# The path points to the HTML page that is used to set the plugin's settings.
# The HTML page is in some funky HTML-like format that is used to display the
# settings page when you select "Settings->Extras->[plugin's settings box]"
# from the SC7 window.
sub page {
	return 'plugins/SqueezeCloud/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.squeezecloud'), qw(playmethod));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{code} && $params->{code} ne '') {
		$log->debug('Getting access token and refresh token from code');
		Plugins::SqueezeCloud::Oauth2::getAuthorizationToken(\&handler, @_);
		return;
	}
	elsif ($params->{logout}) {
		$log->debug('Request to log out');
		Plugins::SqueezeCloud::Oauth2::logout(\&handler, @_);
		return;
	}

	if (Plugins::SqueezeCloud::Oauth2::isLoggedIn()) {

		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$log->debug('Successful request for user info.');
				my $response = shift;
				my $result = eval { from_json($response->content) };
				$log->info('You are logged in to SoundCloud as ' . $result->{username});
				$params->{username} = $result->{username};

				$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
			},
			sub {
				$log->error('Failed request for user info.');
				$log->error($_[1]);
				$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
			},
			{
				timeout => 15,
			}
		);

		if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
			Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&handler, @_);
			return;
		}

		$http->get('https://api.soundcloud.com/me', Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
	}
	else {
		$log->debug('Generating code and code challange');
		my $codeChallenge = Plugins::SqueezeCloud::Oauth2::getCodeChallenge;
		$params->{codeChallenge} = $codeChallenge;
		$params->{hostName} = Slim::Utils::Misc::getLibraryName();

		$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
	}
}

# Always end with a 1 to make Perl happy
1;
