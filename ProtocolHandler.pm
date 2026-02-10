package Plugins::SqueezeCloud::ProtocolHandler;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by David Blackman (first release),
#   Robert Gibbon (improvements),
#   Daniel Vijge (improvements),
#   KwarkLabs (major SoundCloud API changes)
#
# See file LICENSE for full license details

use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);
use Plugins::SqueezeCloud::Oauth2;

my $log   = logger('plugin.squeezecloud');
my $cache = Slim::Utils::Cache->new('squeezecloud');

my %fetching; # hash of ids we are fetching metadata for to avoid multiple fetches

Slim::Player::ProtocolHandlers->registerHandler('soundcloud', __PACKAGE__);

use strict;
use base 'Slim::Player::Protocols::HTTP';

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;
use constant META_CACHE_TTL => 86400 * 30; # 24 hours x 30 = 30 days

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
	SSL_verify_mode => Net::SSLeay::VERIFY_NONE()
) if preferences('server')->get('insecureHTTPS');

my $prefs = preferences('plugin.squeezecloud');

my $prefix = 'sc:';

sub canSeek { 0 }

sub _makeMetadata {
	my ($json) = shift;

	$log->debug('ProtocolHandler _makeMetadata started.');

	my $year;
	if (int($json->{'release_year'}) > 0) {
		$year = int($json->{'release_year'});
	} elsif ($json->{'created_at'}) {
		$year = substr $json->{'created_at'}, 0, 4;
	}

	my $icon = getBetterArtworkURL($json->{'artwork_url'} || "");
	my $DATA = {
		urn => $json->{'urn'},
		duration => $json->{'duration'} / 1000,
		name => $json->{'title'},
		title => $json->{'title'},
		artist => $json->{'user'}->{'username'},
		album => "SoundCloud",
		play => "soundcloud://" . $json->{'urn'},
		#url  => $json->{'permalink_url'},
		#link => "soundcloud://" . $json->{'urn'},
		bitrate => '160kbps',
		bpm => (int($json->{'bpm'}) > 0 ? int($json->{'bpm'}) : ''),
		type => 'AAC (SoundCloud)',
		icon => $icon,
		image => $icon,
		cover => $icon,
		year => ($year ? $year : ''),
		on_select => 'play',
		genre => $json->{'genre'},
	};
}

sub getStreamURL {
	my $json = shift;
	$log->debug('getStreamURL started.');

	my $ua = LWP::UserAgent->new(
		requests_redirectable => [],
	);

	# Need to call the /streams endpoint for the tracks API endpoint. This returns an object with the different stream options
	my $res = $ua->get($json->{'uri'}.'/streams', Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );
	my $stream_res = eval { from_json( $res->content ) };

	# Define the different formats supported in order of preference
	foreach ('hls_aac_160_url', 'hls_aac_96_url', 'hls_mp3_128_url', 'http_mp3_128_url') {
		my $format = $_;
		if (exists $stream_res->{$format}) {
			$log->info('Found format '.$format.', URL '.$stream_res->{$format}.', getting redirect location');

			my $ua = LWP::UserAgent->new(
				requests_redirectable => [],
			);

			my $res = $ua->get($stream_res->{$format}, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );

			my $redirector = $res->header( 'location' );

			if (!$redirector) {
				$log->warn('Warning: Failed to get redirect location for '.$format.' from '.$stream_res->{$format});
				$log->info($res->status_line);
				next;
			}

			$log->info('Final URL that can be played: '.$redirector);
			return $redirector;
		}
	}
	
	$log->error('Error: correct format could not be found in streams. Only available formats are ' . join(', ' , keys(%$stream_res)));
	return;
}

sub getBetterArtworkURL {
	my $artworkURL = shift;
	$artworkURL =~ s/-large/-t500x500/g;
	return $artworkURL;
}

sub getFormatForURL { 'soundcloud' } # custom-convert type

sub isRemote { 1 }

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub gotNextTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $song   = $http->params->{song};
	my $url    = $song->currentTrack()->url;
	my $track  = eval { from_json( $http->content ) };

	if ( $@ || $track->{error} ) {

		# We didn't get the next track to play
		if ( $log->is_warn ) {
			$log->warn( 'Soundcloud error getting next track: ' . ( $@ || $track->{error} ) );
		}

		if ( $client->playingSong() ) {
			$client->playingSong()->pluginData( {
				songName => $@ || $track->{error},
			} );
		}

		$http->params->{'errorCallback'}->( 'PLUGIN_SQUEEZECLOUD_NO_INFO', $track->{error} );
		return;
	}

	# Save metadata for this track
	$song->pluginData( $track );

	my $stream = getStreamURL($track);

	if (!$stream) {
		$http->params->{'errorCallback'}->( 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED', $track->{error} );	
		return;
	}

	$song->streamUrl($stream);

	my $meta = _makeMetadata($track);
	$song->duration( $meta->{duration} );

	$log->info("setting ". 'soundcloud_meta_' . $track->{urn});
	$cache->set($prefix . 'track' . '-' . $track->{urn} , $meta, META_CACHE_TTL);

	$http->params->{callback}->();
}

sub gotNextTrackError {
	my $http = shift;
	$log->error('Error getting track '.$http->url.' - '.$http->error);
	$http->params->{errorCallback}->( 'PLUGIN_SQUEEZECLOUD_ERROR', $http->error );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $client = $song->master();
	my $url    = $song->currentTrack()->url;

	# Get next track
	my ($urn) = $url =~ m{^soundcloud://(.*)$};

	# Convert old id that might still be in favourites or cache to urn
	$urn = 'soundcloud:tracks:'.$urn unless $urn =~ /^soundcloud:tracks:/;

	# Talk to SN and get the next track to play
	my $trackURL = "https://api.soundcloud.com/tracks/" . $urn;

	if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
			Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&getNextTrack, @_);
			return;
		}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotNextTrack,
		\&gotNextTrackError,
		{
			client        => $client,
			song          => $song,
			callback      => $successCb,
			errorCallback => $errorCb,
			timeout       => 35,
		},
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting track from soundcloud for $urn");

	$http->get( $trackURL, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );
}

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();

	$log->info( 'Remote streaming Soundcloud track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
	} ) || return;

	${*$sock}{contentType} = 'audio/mpeg';

	return $sock;
}


# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;

	my $url = $track->url;
	$log->info("trackInfo: " . $url);
}

# Track Info menu
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	$log->info("trackInfoURL: " . $url);
	return undef;
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	my $args = { params => {isProtocolHandler => 1}};
	return Plugins::SqueezeCloud::Plugin::metadata_provider($client, $url, $args);
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;

	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL() );
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED' );
}

sub explodePlaylist {
	my ( $class, $client, $uri, $callback ) = @_;

	if ( $uri =~ Plugins::SqueezeCloud::Plugin::PAGE_URL_REGEXP ) {
		Plugins::SqueezeCloud::Plugin::urlHandler(
			$client,
			sub { $callback->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
			{'search' => $uri},
		);
	}
	else {
		$callback->([$uri]);
	}
}

1;
