package Plugins::SqueezeCloud::Plugin;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by David Blackman (first release), 
#   Robert Gibbon (improvements),
#   Daniel Vijge (improvements),
#   Robert Siebert (improvements),
#   KwarkLabs (major SoundCloud API changes)
#
# See file LICENSE for full license details

use strict;
use utf8;
use Encode;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use LWP::Simple;
use LWP::UserAgent;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);
use POSIX qw(strftime);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::SqueezeCloud::Oauth2;
# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;

# The maximum items that can be fetched via the API in one call - 200
use constant API_MAX_ITEMS_PER_CALL => 200;

# The default number of items to fetch in one API call
use constant API_DEFAULT_ITEMS_COUNT => 50;

# The maximum value that should be fetched via the API.
# It is not advisable to increase this value.
use constant API_MAX_ITEMS => 400;

# Which URLs should we catch when pasted into the "Tune In URL" field?
use constant PAGE_URL_REGEXP => qr{^https?://soundcloud\.com/};

use constant META_CACHE_TTL => 86400 * 30; # 24 hours x 30 = 30 days

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
	SSL_verify_mode => Net::SSLeay::VERIFY_NONE() 
) if preferences('server')->get('insecureHTTPS');

my $log;
my $compat;
my $cache = Slim::Utils::Cache->new('squeezecloud');
my $prefix = 'sc:';

# This is the entry point in the script
BEGIN {
	# Initialize the logging
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.squeezecloud',
		'defaultLevel' => 'WARN',
		'description'  => string('PLUGIN_SQUEEZECLOUD'),
	});   

	# Always use OneBrowser version of XMLBrowser by using server or packaged 
	# version included with plugin
	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

# Get the data related to this plugin and preset certain variables with 
# default values in case they are not set
my $prefs = preferences('plugin.squeezecloud');
$prefs->init({ refresh_token => "", playmethod => "stream" });

# This is called when squeezebox server loads the plugin.
# It is used to initialize variables and the like.
sub initPlugin {
	$log->debug('initPlugin started.');
    my $class = shift;
	
    # Initialize the plugin with the given values. The 'feed' is the first
    # method called. The available menu entries will be shown in the new 
    # menu entry 'soundcloud'. 
    $class->SUPER::initPlugin(
        feed   => \&toplevel,
        tag    => 'squeezecloud',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') ? 1 : undef,
        weight => 10,
    );
	
	# clear the cache when user enters an apiKey
	$prefs->setChange(sub {
		my ($pref, $new, $obj, $old) = @_;
		$cache->clear;
	}, 'apiKey');

    if (!$::noweb) {
        require Plugins::SqueezeCloud::Settings;
        Plugins::SqueezeCloud::Settings->new;
    }

    Slim::Formats::RemoteMetadata->registerProvider(
        match => qr/soundcloud\.com/,
        func => \&metadata_provider,
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        soundcloud => 'Plugins::SqueezeCloud::ProtocolHandler'
    );

	Slim::Player::ProtocolHandlers->registerURLHandler(
	    PAGE_URL_REGEXP() => 'Plugins::SqueezeCloud::ProtocolHandler'
	) if Slim::Player::ProtocolHandlers->can('registerURLHandler');
	
	$log->debug('initPlugin ended.');
}

# Called when the plugin is stopped
sub shutdownPlugin {
	$log->debug('shutdownPlugin started.');
    my $class = shift;
}

# Returns the name to display on the squeezebox
sub getDisplayName { 'PLUGIN_SQUEEZECLOUD' }

# Returns the default metadata for the track which is specified by the URL.
# In this case only the track title that will be returned.
sub defaultMeta {
	$log->debug('defaultMeta started.');
	my ( $client, $url ) = @_;
	
	return {
		title => Slim::Music::Info::getCurrentTitle($url)
	};
	
	$log->debug('defaultMeta ended.');
}

# Extracts the available metadata for a tracks from the JSON data. The data 
# is cached and then returned to be presented to the user. 
sub _makeMetadata {
	$log->debug('_makeMetadata started.');
	my ($client, $json, $args) = @_;
	
	# this is ugly... for whatever reason the EN/Classic skins can't handle tracks with an items element
	# The protocol handler cannot handle tracks with an item element either...
	my $simpleTracks = ($args->{params} && (($args->{params}->{isWeb} && preferences('server')->get('skin')=~ /Classic|EN/i) || $args->{params}->{isProtocolHandler})) ? 1 : 0;
	
	my $isFromCache = ($args->{params} && $args->{params}->{isFromCache});
											 
    # Get the icon from the artwork_url.
    # Get the 500x500 high quality version, as specified in SoundCloud API.
	my $icon = "";
	if (defined $json->{'artwork_url'}) {
		$icon = $json->{'artwork_url'};
		$icon =~ s/-large/-t500x500/g;
	}
		
	my $trackinfo = [];
	
	my $duration;
	if ($json->{'duration'}) {
        $duration = $json->{'duration'} / 1000;
		$duration = sprintf('%s:%02s', int($duration / 60), int($duration % 60));
	}
	
	my $year;
	if (int($json->{'release_year'}) > 0) {
		$year = int($json->{'release_year'});
	} elsif ($json->{'created_at'}) {
		$year = substr $json->{'created_at'}, 0, 4;
	}
	
	push @$trackinfo, {
		name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . $duration,
		type => 'text',
	} if $duration;

	push @$trackinfo, {
		name => cstring($client, 'YEAR') . cstring($client, 'COLON') . ' ' . $year,
		type => 'text',
	} if $year;

	# It is a requirement of the SoundCloud API Terms to include this link.
	push @$trackinfo, {
		name => string('PLUGIN_SQUEEZECLOUD_LINK') . cstring($client, 'COLON') . ' ' . $json->{'permalink_url'},
		type => 'text',
	} if $json->{'permalink_url'};
	
	push @$trackinfo, {
		type => 'link',
		name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $json->{'user'}->{'username'},
		url  => \&tracksHandler,
		passthrough => [ { uid => $json->{'user'}->{'id'}, type => 'friend', parser => \&_parseFriend } ]
	} if $json->{'user'}->{'id'};

	push @$trackinfo, {
		type => 'link',
		name => string('PLUGIN_SQUEEZECLOUD_RELATED'),
		url  => \&tracksHandler,
		passthrough => [ { id => $json->{'id'}, type => 'releated', parser => \&_parseTracks } ]
	} if $json->{'user'}->{'id'};

	if ($json->{'user_favorite'} ne 1) {	
		push @$trackinfo, {
			type => 'link',
			name => string('PLUGIN_SQUEEZECLOUD_LIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACK'),
			url  => \&likeTrack,
			passthrough => [ { id => $json->{'id'}, type => 'text', parser => \&_parseTracks } ]
		};
	} else {
		push @$trackinfo, {
			type => 'link',
			name => string('PLUGIN_SQUEEZECLOUD_UNLIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACK'),
			url  => \&unlikeTrack,
			passthrough => [ { id => $json->{'id'}, type => 'text', parser => \&_parseTracks } ]
		};
	}
	
	my $DATA;
	if ($simpleTracks) {
		$log->debug('_makeMetadata simpleTracks used.');
		$DATA = {
			id => $json->{'id'},
			duration => $json->{'duration'} / 1000,
			name => $json->{'title'},            
			title => $json->{'title'},
			artist => $json->{'user'}->{'username'},
			album => "SoundCloud",
			play => "soundcloud://" . $json->{'id'},
			#url  => $json->{'permalink_url'},
			#link => "soundcloud://" . $json->{'id'},
			bitrate => '128kbps',
			bpm => (int($json->{'bpm'}) > 0 ? int($json->{'bpm'}) : ''),
			type => 'MP3 (SoundCloud)',
			icon => $icon,
			image => $icon,
			cover => $icon,
			year => ($year ? $year : ''),
			on_select => 'play',
		}
	} else {
		$DATA = {
			id => $json->{'id'},
			duration => $json->{'duration'} / 1000,
			name => $json->{'title'},
			# line1 and line2 are used in browse view
			# artist and title are used in the now playing and playlist views
			line1 => $json->{'user'}->{'username'} && $json->{'title'} . ' (' . $duration . ')',
			line2 => $json->{'user'}->{'username'} . ( $year ? ' (' . $year . ')' : ''),
			title => $json->{'title'} . ' (' . $duration . ')',
			artist => $json->{'user'}->{'username'},
			album => "SoundCloud",
			play => "soundcloud://" . $json->{'id'},
			#url  => $json->{'permalink_url'},
			#link => "soundcloud://" . $json->{'id'},
			bitrate => '128kbps',
			bpm => (int($json->{'bpm'}) > 0 ? int($json->{'bpm'}) : ''),
			type => 'MP3 (SoundCloud)',
			icon => $icon,
			image => $icon,
			cover => $icon,
			year => ($year ? $year : ''),,
			on_select => 'play',
			items => $trackinfo,
			playall     => 0,
			passthrough => [{
				track_id => $json->{'id'}
			}]
		}
	}
 
	if (!$isFromCache) {
		# Re-write the cache data here to reset TTL but also because it might not be complete and it might have changed.
		_cacheWriteTrack($DATA);
    }
    	
	$log->debug('_makeMetadata ended.');
	
	return \%$DATA;
}

sub _cacheWriteTrack {
	$log->debug('_cacheWriteTrack started.');
	my ($track) = @_;
	my $searchType = 'track';
	$log->debug('_cacheWriteTrack ID: ' . $track->{'id'});	
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-duration', $track->{'duration'} * 1000, META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-name', encode_utf8($track->{'name'}), META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-artist', encode_utf8($track->{'artist'}), META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-artwork_url', $track->{'icon'}, META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-bpm', (int($track->{'bpm'}) > 0 ? int($track->{'bpm'}) : ''), META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'} . '-year', (int($track->{'year'}) > 0 ? int($track->{'year'}) : ''), META_CACHE_TTL);
	$cache->set($prefix . $searchType . '-' . $track->{'id'}, $track->{'id'}, META_CACHE_TTL);
	$log->debug('_cacheWriteTrack ended.');
}

sub _cacheReadTrack {
	$log->debug('_cacheReadTrack started.');
	my ($id) = @_;
	my %track;
	my $searchType = 'track';
	$track{duration} = $cache->get($prefix . $searchType . '-' . $id . '-duration');
	$track{name} = $cache->get($prefix . $searchType . '-' . $id . '-name');
	$track{title} = decode_utf8($track{name});
	$track{artist} = decode_utf8($cache->get($prefix . $searchType . '-' . $id . '-artist'));
	$track{user} = {username  => $track{artist}};
	$track{artwork_url} = $cache->get($prefix . $searchType . '-' . $id . '-artwork_url');
	$track{bpm} = $cache->get($prefix . $searchType . '-' . $id . '-bpm');
	$track{year} = $cache->get($prefix . $searchType . '-' . $id . '-year');
	$track{id} = $id;
	$log->debug('_cacheReadTrack ID: ' . $track{'id'} . ' ' . $id);
	$log->debug('_cacheReadTrack ended.');
	return \%track;
}

sub likeTrack {
	$log->debug('likeTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $id = $passDict->{'id'} || '';
	my $url = $method . "://api.soundcloud.com/likes/tracks/$id";
    $log->debug("Liking: $url");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&likeTrack, @_);
    	return;
    }

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Like Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_LIKED') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACK'), type => 'text' } ]);
		} else {
			$log->warn("Like Track Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text' } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
	
	$fetch->();
	
	$log->debug('likeTrack ended.');
}

sub unlikeTrack {
	$log->debug('unlikeTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $id = $passDict->{'id'} || '';
	my $url = $method . "://api.soundcloud.com/likes/tracks/$id";
    $log->debug("Unliking: $url");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&unlikeTrack, @_);
    	return;
    }

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unlike Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_UNLIKED') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACK'), type => 'text' } ]);
		} else {
			$log->warn("Unlike Track Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_TRACK') . name => string('PLUGIN_SQUEEZECLOUD_LIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_NOT_FOUND'), type => 'text' } ]);
		}
		
		#$log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unlikeTrack ended.');
}

# This method is called when the Slim::Networking::SimpleAsyncHTTP encountered 
# an error or no http repsonse was received. 
sub _gotMetadataError {
	$log->debug('_gotMetadataError started.');
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');
	my $error  = $http->error;
	
	$log->is_debug && $log->debug( "Error fetching Web API metadata: $error" );
	
	$client->master->pluginData( webapifetchingMeta => 0 );
	
	# To avoid flooding the SoundCloud servers in the case of errors, we just ignore further
	# metadata for this track if we get an error
	my $meta = defaultMeta( $client, $url );
	$meta->{_url} = $url;
	
	$client->master->pluginData( webapimetadata => $meta );
	
	$log->debug('_gotMetadataError ended.');
}

# This method is called when the Slim::Networking::SimpleAsyncHTTP 
# method has received a http response.
sub _gotMetadata {
	$log->debug('_gotMetadata started.');
	my $http      = shift;
	my $client    = $http->params('client');
	my $url       = $http->params('url');
	my $content   = $http->content;

    # Check if there is an error message from the last eval() operator
	if ( $@ ) {
		$http->error( $@ );
		_gotMetadataError( $http );
		return;
	}

	$client->master->pluginData( webapifetchingMeta => 0 );
		
	my $json = eval { from_json($content) };
	my $user_name = $json->{'user'}->{'username'};

	#  _gotMetadata is only called from ProtocolHandler and cannot handle track items.
	my $args = { params => {isProtocolHandler => 1}};

	my $DATA = _makeMetadata($client, $json, $args );

	my $ua = LWP::UserAgent->new(
		requests_redirectable => [],
	);

	my $res = $ua->get( getStreamURL($json), Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );

	my $stream = $res->header( 'location' );
	
	$log->debug('_gotMetadata ended.');

	return;
}

# Returns either the stream URL or the download URL from the given JSON data. 
sub getStreamURL {
	$log->debug('getStreamURL started.');
	my $json = shift;
	
	if ($prefs->get('playmethod') eq 'download' && exists($json->{'download_url'}) && defined($json->{'download_url'}) && $json->{'downloadable'} eq '1') {
		$log->debug('download_url: ' . $json->{'download_url'});
		return $json->{'download_url'};
	}
	else {
		$log->debug('stream_url: ' . $json->{'stream_url'});
		return $json->{'stream_url'};
	}
}

sub fetchMetadata {
	$log->debug('fetchMetadata started.');
	my ( $client, $url ) = @_;
	
	if ($url =~ /soundcloud\:\/\/(.*)/i) {
		my $resource = 'tracks/' . $1;
		my $method = "https";
		# my $params .= "&filter=streamable";
		my $params .= "";
		my $extras = "linked_partitioning=true&limit=1";
		my $queryUrl = $method."://api.soundcloud.com/".$resource."?" . $extras . $params;
		
		if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
			Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&fetchMetadata, @_);
			return;
		}

        # Call the server to fetch the data via the asynchronous http request. 
        # The methods are called when a response was received or an error 
        # occurred. Additional information to the http call is passed via 
        # the hash (third parameter).
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			\&_gotMetadata,
			\&_gotMetadataError,
			{
				client     => $client,
				url        => $url,
				timeout    => HTTP_TIMEOUT,
			},
		);

		$http->get($queryUrl, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
	}
	
	$log->debug('fetchMetadata ended.');
}

sub _parseTracks {
	$log->debug('_parseTracks started.');
	my ($client, $json) = @_;
	my $menuEntries = [];

	for my $entry (@{$json->{'collection'}}) {
		if ($entry->{'streamable'}) {
			push @$menuEntries, _makeMetadata($client, $entry);
		}
	}
	
	return $menuEntries;	
	$log->debug('_parseTracks ended.');
}

# Main method that is called when the user selects a menu item. It is 
# specified in the menu array by the key 'url'. The passthrough array 
# contains the additional values that is passed to this method to 
# differentiate what shall be done in here.
sub tracksHandler {
	$log->debug('tracksHandler started.');
	my ($client, $callback, $args, $passDict) = @_;

    # Get the index (offset) where to start fetching items
	my $index = ($args->{'index'} || 0); # ie, offset
	my $menu = [];    
	
	# The number of items to fetch, either specified in arguments or the maximum possible.
	my $pageSize = min(API_MAX_ITEMS_PER_CALL || API_MAX_ITEMS);
	my $quantity = API_MAX_ITEMS;

	my $searchType = $passDict->{'type'};
	my $searchStr = ($searchType eq 'tags') ? "tags=" : "q=";
	my $search   = $args->{'search'} ? $searchStr . URI::Escape::uri_escape_utf8($args->{'search'}) : '';

    # The parser is the method that will be called when the 
    # server has returned some data in the SimpleAsyncHTTP call.
	my $parser = $passDict->{'parser'} || \&_parseTracks;

	my $params = $passDict->{'params'} || '';

	my $method = "https";
	my $uid = $passDict->{'uid'} || '';

	# If this is set to one then the user has provided the API key. This 
	# is the case when the menu item in the toplevel method are active.
	my $authenticated = 0;
	my $extras = '';
	my $resource;
	
	# Check the given type (defined by the passthrough array). Depending 
	# on the type certain URL parameters will be set. 
	if ($searchType eq 'playlists') {
		my $id = $passDict->{'pid'} || '';
		$authenticated = 1;

		if ($id eq '') {
			if ($uid ne '') {
				$resource = "users/$uid/playlists";
			}
			elsif ($search ne '') {
				$resource = "playlists";
			}
			else {
				$resource = "me/playlists";
			}
		} else {
			$resource = "playlists/$id";
		}
		$extras = "access=playable,preview&linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'liked_playlists') {
		$authenticated = 1;
		$resource = "me/likes/playlists";
		$extras = "access=playable,preview&linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'tracks') {
		$authenticated = 1;
		$resource = "users/$uid/tracks";
		$extras = "access=playable,preview&linked_partitioning=true&limit=" . $quantity;

	} elsif ($searchType eq 'releated') {
		$quantity = API_DEFAULT_ITEMS_COUNT;
		my $id = $passDict->{'id'} || '';
		$authenticated = 1;
		$resource = "tracks/$id/related";
		$extras = "access=playable,preview&linked_partitioning=true&limit=" . $quantity;
		
	} elsif ($searchType eq 'favorites') {
		$authenticated = 1;
		$resource = "users/$uid/likes/tracks";
		if ($uid eq '') {
			$resource = "me/likes/tracks";
		}
		$extras = "linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'friends') {
		$authenticated = 1;
		$resource = "me/followings";
		$extras = "linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'users') {
		# Override maximum quantity
		$quantity = API_DEFAULT_ITEMS_COUNT;
		$authenticated = 1;
		$resource = "users";
		$extras = "linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'friend') {
		$authenticated = 1;
		$resource = "users/$uid";
		$extras = "linked_partitioning=true&page_size=" . $pageSize;

	} elsif ($searchType eq 'activities') {
		$authenticated = 1;
		# Override maximum quantity
		# $quantity = API_DEFAULT_ITEMS_COUNT;
		$resource = "me/activities";
		$extras = "access=playable,preview&linked_partitioning=true&limit=" . $quantity;
		
	} else {
		$resource = "tracks";
		# Override maximum quantity
		$quantity = API_DEFAULT_ITEMS_COUNT;
		# $params .= "&filter=streamable";
		# access parameter only works with a search input
		if ( $args->{'search'} ) {
			$params .= "&access=playable,preview";
		}
		$extras = "linked_partitioning=true&limit=" . $quantity;
	}
	
	my $queryUrl = $method."://api.soundcloud.com/".$resource."?" . $extras . $params . "&" . $search;	

	$log->debug("fetching: " . $queryUrl);
	
	_getTracks($client, $searchType, $index, $quantity, $queryUrl, $uid, 0, $parser, $callback, $menu);
	
	$log->debug('tracksHandler ended.');
}

sub _getTracks {
	$log->debug('_getTracks started.');
	my ($client, $searchType, $index, $quantity, $queryUrl, $uid, $cursor, $parser, $callback, $menu) = @_;
	
	if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
		Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&_getTracks, @_);
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		# Called when a response has been received for the request.
		sub {
			my $http = shift;
			my $json = eval { from_json($http->content) };
			my $next_href = $json->{'next_href'} || '';
			my $returnedMenu = [];
	
			$returnedMenu = $parser->($client, $json);

			for my $entry (@$returnedMenu) {
				push @$menu, $entry;
			};
			
			my $total = scalar @$menu;
			
			# Queries that uses pagesize need the recursion to be terminated before next_href is empty. (first half of if-statement)
			# Queries that accept the limit parameter do not need the recursion terminated early. (second half of if-statement)
			if ((($searchType ne 'tracks' || $searchType ne 'activities' || $searchType ne 'related' || $searchType ne 'tags' || !defined($searchType))
				 && ($total >= $quantity || $total % $quantity != 0)) ||
				($next_href eq '')) {
				
				if ($searchType eq 'friends') {
					# Sort by UID
                    # $menu = [ sort { ($a->{passthrough}->[0]->{'uid'}) <=> ($b->{passthrough}->[0]->{'uid'}) } @$menu ];
					# Sort by Name.
					$menu = [ sort { uc($a->{name}) cmp uc($b->{name}) } @$menu ];
                }
				
				my $i = 1;
				if ($searchType eq 'tracks') {	
					for my $entry (@$menu) {
						_cacheWriteTrack($entry);
						$i++;
					}
				
					# Store the total in the cache last so that this is the last TTL to expire.
					# If the total is in the cache then all the data should still be cached.
					$cache->set($prefix . $searchType . $uid . '-' . '-total', ($total), META_CACHE_TTL);
				}

				_callbackTracks($menu, $index, $quantity, $callback);
				
            } else {
				$cursor = $total + 1;
				_getTracks($client, $searchType, $index, $quantity, $next_href, $uid, $cursor, $parser, $callback, $menu);
			}
            
		},
		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->([ { name => $_[1], type => 'text' } ]);
		},
		
	)->get($queryUrl, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
	
	$log->debug('_getTracks ended.');
}

sub _callbackTracks {
	$log->debug('_callbackTracks started.');
	my ( $menu, $index, $quantity, $callback ) = @_;

	my $total = scalar @$menu;
	if ($quantity ne 1) {
        $quantity = min($quantity, $total - $index);
    }	
	
	my $returnMenu = [];
	
	my $i = 0;
	my $count = 0;
	for my $entry (@$menu) {
		if ($i >= $index && $count < $quantity) {
            push @$returnMenu, $entry;
			$count++;
        }
		$i++;
	}
	
	$callback->({
		items  => $returnMenu,
		offset => $index,
		total  => $total,
	});
    $log->debug('_callbackTracks ended.');
}

sub metadata_provider {
	$log->debug('metadata_provider started.');
	my ( $client, $url, $args ) = @_;

	my $id = track_key($url);
	my $searchType = 'track';
	if ( $cache->get($prefix . $searchType . '-' . $id)) {
        $log->debug('Metadata cache hit on ID: ' . $id);
		my $params = $args->{params};
		$params->{isFromCache} = 1;
		$args->{params} = $params;
		return _makeMetadata($client, _cacheReadTrack($id), $args);
    } else {
		$log->debug('Metadata cache miss. Fetching: ' . $id);
		if ( !$client->master->pluginData('webapifetchingMeta') ) {
			# The fetchMetadata method will invoke an asynchronous http request. This will 
			# start a timer that is linked with the method fetchMetadata. Kill any pending 
			# or running request that is already active for the fetchMetadata method. 
			Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );
	
			# Start fetching new metadata in the background
			$client->master->pluginData( webapifetchingMeta => 1 );
			fetchMetadata( $client, $url );
		};
	}
	
	$log->debug('metadata_provider ended.');
	
	return { };
}

# This method is called when the user has selected the last main menu where 
# an URL can be entered manually. It will assemble the given URL and fetch 
# the data from the server.
sub urlHandler {
	$log->debug('urlHandler started.');
	my ($client, $callback, $args) = @_;
	
	my $url = $args->{'search'};

	# Remove mobile website prefix
	$url =~ s/\/\/m./\/\//;
	
	$url = URI::Escape::uri_escape_utf8($url);
	my $queryUrl = "https://api.soundcloud.com/resolve?url=$url";
    $log->debug("fetching: $queryUrl");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&urlHandler, @_);
    	return;
    }

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

				if (exists $json->{'tracks'}) {
					$callback->({ items => [ _parsePlaylist($json) ] });
				} else {
					$callback->({
						items => [ _makeMetadata($client, $json) ]
					});
				}
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
		)->get($queryUrl, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
	};
		
	$fetch->();
	
	$log->debug('urlHandler ended.');
}

# Get the tracks data from the JSON array and passes it to the parseTracks 
# method which will then add a menu item for each track
sub _parsePlaylistTracks {
	$log->debug('_parsePlaylistTracks started.');
	my ($client, $json) = @_;
	my $menuEntries = [];
	
	$log->debug('sizesize: ' . scalar @{$json->{'tracks'}});
	
	for my $entry (@{$json->{'tracks'}}) {
		if ($entry->{'streamable'}) {
			push @$menuEntries, _makeMetadata($client, $entry);
		}
	}
	
	# Get the icon from the artwork_url. If no url is defined, set the default icon.
    my $icon = '/html/images/favorites.png';
	push @$menuEntries, {
		type => 'link',
		name => string('PLUGIN_SQUEEZECLOUD_LIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_PLAYLIST'),
		url  => \&likePlaylist,
		icon => $icon,
		image => $icon,
		cover => $icon,
		passthrough => [ { pid => $json->{'id'}, type => 'text', parser => \&_parsePlaylist } ]
	};
	
	$icon = '/html/images/favorites_remove.png';
	push @$menuEntries, {
		type => 'link',
		name => string('PLUGIN_SQUEEZECLOUD_UNLIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_PLAYLIST'),
		url  => \&unlikePlaylist,
		icon => $icon,
		image => $icon,
		cover => $icon,
		passthrough => [ { pid => $json->{'id'}, type => 'text', parser => \&_parsePlaylist } ]
	};

	
	return $menuEntries;	
	$log->debug('_parsePlaylistTracks ended.');	
}


sub likePlaylist {
	$log->debug('likePlaylist started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $id = $passDict->{'pid'} || '';
	my $url = $method . "://api.soundcloud.com/likes/playlists/$id";
    $log->debug("Liking: $url");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&likePlaylist, @_);
    	return;
    }

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Like Playlist Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_LIKED'), type => 'text' } ]);
		} else {
			$log->warn("Like Playlist Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text' } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
	
	$fetch->();
	
	$log->debug('likePlaylist ended.');
}

sub unlikePlaylist {
	$log->debug('unlikePlaylist started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $id = $passDict->{'pid'} || '';
	my $url = $method . "://api.soundcloud.com/likes/playlists/$id";
    $log->debug("Unliking: $url");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&unlikePlaylist, @_);
    	return;
    }
	
	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unlike Playlist Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_UNLIKED'), type => 'text' } ]);
		} else {
			$log->warn("Unlike Playlist Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_LIKE') . ' ' . string('PLUGIN_SQUEEZECLOUD_NOT_FOUND'), type => 'text' } ]);		
		}
		
		#$log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unlikePlaylist ended.');
}

# Gets more information for the given playlist from the passed data and  
# returns the menu item for it. 
sub _parsePlaylist {
	$log->debug('_parsePlaylist started.');
	my ($client, $entry) = @_;
	my $menuEntry = [];
	
	# Add information about the track count to the playlist menu item
	my $numTracks = 0;
	my $titleInfo = "";
	
	# Add year
	my $year;
	if (int($entry->{'release_year'}) > 0) {
		$year = int($entry->{'release_year'});
	} elsif ($entry->{'created_at'}) {
		$year = substr $entry->{'created_at'}, 0, 4;
	}
	if ($year) {
		$titleInfo .= $year . ' ';
	}
	
	if (exists $entry->{'tracks'} || exists $entry->{'track_count'}) {
		$numTracks = exists $entry->{'tracks'} ? scalar(@{$entry->{'tracks'}}) : scalar($entry->{'track_count'});
		if ($numTracks eq 1) {
            $titleInfo .= "$numTracks " . lc(string('PLUGIN_SQUEEZECLOUD_TRACK'));
        } else {
			$titleInfo .= "$numTracks " . lc(string('PLUGIN_SQUEEZECLOUD_TRACKS'));
		}
	}

    # Add information about the playlist play time
	my $totalSeconds = ($entry->{'duration'} || 0) / 1000;
	if ($totalSeconds != 0) {
		$titleInfo .= ' ' . sprintf('%s:%02s', int($totalSeconds / 60), $totalSeconds % 60);
	}
	
    # Get the icon from the artwork_url. If no url is defined, set the default icon.
	# Shared playlists have a null artwork_url which SoundCloud might fix at some future date.
    my $icon = "";
    if (defined $entry->{'artwork_url'}) {
        $icon = $entry->{'artwork_url'};
        $icon =~ s/-large/-t500x500/g;
    }

    # Get the title and add the additional information to it
    my $title = $entry->{'title'};
	if ($titleInfo) {
        $title .= " ($titleInfo)";
    }

	# Create the menu array
	$menuEntry = {
		name => $title,
		type => 'playlist',
		icon => $icon,
		url => \&tracksHandler,
		passthrough => [ { type => 'playlists', pid => $entry->{'id'}, parser => \&_parsePlaylistTracks }],
	};
	
	$log->debug('_parsePlaylist ended.');
	
	return $menuEntry;
}

# Parses the available playlists from the JSON array and gets the information 
# for each playlist. Each playlist will be added as a separate menu entry.
sub _parsePlaylists {
	$log->debug('_parsePlaylists started.');
	my ($client, $json) = @_;
	my $menuEntries = [];

	for my $entry (@{$json->{'collection'}}) {
		push @$menuEntries, _parsePlaylist($client, $entry);
	};
	
	return $menuEntries;
	$log->debug('_parsePlaylists ended.');
}

# Shows the three available menu entries favorites, tracks and playlists 
# with the received count information for a selected friend. 
sub _parseFriend {
	$log->debug('_parseFriend started.');
	my ($client, $entry) = @_;
	my $menuEntries = [];

	my $image = $entry->{'avatar_url'};
	my $name = $entry->{'username'} || $entry->{'full_name'};
	my $favorite_count = $entry->{'public_favorites_count'};
	my $track_count = $entry->{'track_count'};
	my $playlist_count = $entry->{'playlist_count'};
	my $id = $entry->{'id'};

	if ($favorite_count > 0) {
        push @$menuEntries, {
    		name => string('PLUGIN_SQUEEZECLOUD_FAVORITES'),
    		type => 'playlist',
    		url => \&tracksHandler,
    		passthrough => [ { type => 'favorites', uid => $id, max => $favorite_count }],
    	};
    }

	if ($track_count > 0) {
        push @$menuEntries, {
    		name => string('PLUGIN_SQUEEZECLOUD_TRACKS'),
    		type => 'playlist',
    		url => \&tracksHandler,
    		passthrough => [ { type => 'tracks', uid => $id, max => $track_count }],
    	};
    }
	
	if ($playlist_count > 0) {
        push @$menuEntries, {
    		name => string('PLUGIN_SQUEEZECLOUD_PLAYLISTS'),
    		type => 'link',
    		url => \&tracksHandler,
    		passthrough => [ { type => 'playlists', uid => $id, max => $playlist_count,
    		parser => \&_parsePlaylists } ]
    	};
    }
	
	push @$menuEntries, {
		type => 'link',
		name => string('PLUGIN_SQUEEZECLOUD_FOLLOW'),
		url  => \&followFriend,
		passthrough => [ { uid => $id, type => 'friend', parser => \&_parseFriend } ]
	};
	
	push @$menuEntries, {
		type => 'link',
		name => string('PLUGIN_SQUEEZECLOUD_UNFOLLOW'),
		url  => \&unfollowFriend,
		passthrough => [ { uid => $id, type => 'text', parser => \&_parseFriend } ]
	};

	
	$log->debug('_parseFriend ended.');
	
	return $menuEntries;
}

sub followFriend {
	$log->debug('followFriend started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $uid = $passDict->{'uid'} || '';
	my $url = $method . "://api.soundcloud.com/me/followings/$uid";
    $log->debug("Following: $url");

    if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
    	Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&followFriend, @_);
    	return;
    }

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Follow Friend Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_FOLLOWED'), type => 'text' } ]);
		} else {
			$log->warn("Follow Friend Error: " . $response->status_line());
			# $callback->([ { name => $response->status_line(), type => 'text' } ]);
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_ARTIST') . ' ' . string('PLUGIN_SQUEEZECLOUD_NOT_FOUND'), type => 'text' } ]);	
		}
	};
		
	$fetch->();
	
	$log->debug('followFriend ended.');
}

sub unfollowFriend {
	$log->debug('unfollowFriend started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $uid = $passDict->{'uid'} || '';
	my $url = $method . "://api.soundcloud.com/me/followings/$uid";
    $log->debug("Unfollowing: $url");

	if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
		Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&unfollowFriend, @_);
		return;
	}

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders());
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unfollow Friend Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_UNFOLLOWED'), type => 'text' } ]);
		} elsif ( $response->code() eq 404 ) {
			$log->warn("Unfollow Friend Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_SQUEEZECLOUD_FOLLOW') . ' ' . string('PLUGIN_SQUEEZECLOUD_NOT_FOUND'), type => 'text' } ]);
		} else {
			$log->warn("Unfollow Friend Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text' } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unfollowFriend ended.');
}

# Goes through the list of available friends from the JSON data and parses the 
# information for each friend (which is defined in the parseFriend method). 
# Each friend is added as a separate menu entry.
sub _parseFriends {
	$log->debug('_parseFriends started.');
	my ($client, $json) = @_;
	my $menuEntries = [];

	for my $entry (@{$json->{'collection'}}) {
		my $image = $entry->{'avatar_url'};
		my $name = $entry->{'username'} || $entry->{'full_name'};
		my $id = $entry->{'id'};
		
        # Add the menu entry with the information for one friend.
		push @$menuEntries, {
			name => $name,
			icon => $image,
			image => $image,
			type => 'link',
			url => \&tracksHandler,
			passthrough => [ { type => 'friend', uid => $id, parser => \&_parseFriend} ]
		};
	}
	
	return $menuEntries;
	
	$log->debug('_parseFriends ended.');
}

# Parses the given data. If the data is a playlist the number of tracks and 
# some additional data will be retrieved. The playlist or if the data is a 
# track will then be shown as a menu item. 
sub _parseActivity {
	$log->debug('_parseActivity started.');
	my ($client, $entry) = @_;

    my $created_at = $entry->{'created_at'};
    my $origin = $entry->{'origin'};
    my $tags = $entry->{'tags'};
    my $type = $entry->{'type'};

	if ($type =~ /track\:repost.*/) {
		# If the API returned who reposted then we could add it to the trackentry here.
	}
	
	# The .* after playlist in the regex is needed to catch reposts.
    if ($type =~ /playlist.*/) {
		
        my $playlistItem = _parsePlaylist($client, $origin);
	
        my $user = $origin->{'user'};
        my $user_name = $user->{'username'} || $user->{'full_name'};
		
		if ($playlistItem->{'name'}) {
            $playlistItem->{'name'} = $playlistItem->{'name'} . " - " . sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_SHARED_BY') . " %s", $user_name);
        } else {
			$playlistItem->{'name'} = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_SHARED_BY') . " %s", $user_name);
		}
		
		$log->debug('_parseActivity ended.');
        return $playlistItem;
    } else {
        my $track = $origin->{'track'} || $origin;
        my $user = $origin->{'user'} || $track->{'user'};
        my $user_name = $user->{'username'} || $user->{'full_name'};
        $track->{'artist_sqz'} = $user_name;
		
        my $subtitle = "";
        if ($type eq "favoriting") {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_FAVORITED_BY') . " %s", $user_name);
        } elsif ($type eq "comment") {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_COMMETED_BY') . " %s", $user_name);
        } elsif ($type =~ /track/) {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_NEW_TRACK') . " %s", $user_name);
        } else {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_SHARED_BY') . " %s", $user_name);
        }

        my $trackentry = _makeMetadata($client, $track);
		if ($subtitle) {
            $trackentry->{'name'} = $track->{'title'} . " - " . $subtitle;
        } else {
			$trackentry->{'name'} = $track->{'title'};
		}

		$log->debug('_parseActivity ended.');
        return $trackentry;
    }
	
}

# Parses all available items in the collection. 
# Each item can either be a playlist or a track.
sub _parseActivities {
	$log->debug('_parseActivities started.');
	my ($client, $json) = @_;
	my $menuEntries = [];
	
	my $collection = $json->{'collection'};

	for my $entry (@$collection) {
		push @$menuEntries, _parseActivity($client, $entry);
	}
	
	return $menuEntries;
	
	$log->debug('_parseActivities ended.');
}

sub track_key {
	my $url = shift;

	if ($url =~ /soundcloud\:\/\/(.*)/i) {
		return $1;
	}		
	return '';
}

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

# First method that is called after the plugin has been initialized. 
# Creates the top level menu items that the plugin provides.
sub toplevel {
	$log->debug('toplevel started.');
	my ($client, $callback, $args) = @_;

    # These are the available main menus. The variable type defines the menu 
    # type (search allows text input, link opens another menu), the url defines
    # the method that shall be called when the user has selected the menu entry.
    # The array passthrough holds additional parameters that is passed to the 
    # method defined by the url variable.  
	my $callbacks = [];

    # Add the following menu items only when the user is logged in
	if (Plugins::SqueezeCloud::Oauth2::isLoggedIn()) {

		# Menu entry to show all activities (Stream)
		push(@$callbacks, 
			{ name => string('PLUGIN_SQUEEZECLOUD_ACTIVITIES'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { type => 'activities', parser => \&_parseActivities} ] }
		);

		# Menu entry to show the 'friends' the user is following
		push(@$callbacks, 
			{ name => string('PLUGIN_SQUEEZECLOUD_FRIENDS'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { type => 'friends', parser => \&_parseFriends} ] },
		);

		# Menu entry to show the 'playlists' the user is following
        push(@$callbacks, 
            { name => string('PLUGIN_SQUEEZECLOUD_PLAYLISTS'), type => 'link',
                url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists} ] },
        );

		# Menu entry to show the 'playlists' the user is following
        push(@$callbacks, 
            { name => string('PLUGIN_SQUEEZECLOUD_LIKED') . ' ' . string('PLUGIN_SQUEEZECLOUD_PLAYLISTS'), type => 'link',
                url  => \&tracksHandler, passthrough => [ { type => 'liked_playlists', parser => \&_parsePlaylists} ] },
        );

        # Menu entry to show the users favorites
		push(@$callbacks, 
			{ name => string('PLUGIN_SQUEEZECLOUD_LIKED') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACKS'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
		);

		# Menu entry 'New tracks'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_NEW') , type => 'link',   
			url  => \&tracksHandler, passthrough => [ { params => '&order=created_at' } ], }
		);

		# Menu entry 'Hot tracks'
		# An approximation of the 'New & hot: All music genres' set list.
		my $from = (strftime "%Y-%m-%d %H:%M:%S", (localtime(time() - (7 * 24 * 60 * 60))));
		my $to = strftime "%Y-%m-%d %H:%M:%S", localtime;
		my $param = '&' . URI::Escape::uri_escape_utf8('created_at[from]') . '=' . URI::Escape::uri_escape_utf8($from) .
					'&' . URI::Escape::uri_escape_utf8('created_at[to]') . '=' . URI::Escape::uri_escape_utf8($to);
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_HOT') . ' ' . string('PLUGIN_SQUEEZECLOUD_TRACKS'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ { params => $param . '&order=hotness' } ], }
		);

		
		# Menu entry 'Search'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_SEARCH'), type => 'search',   
			url  => \&tracksHandler, passthrough => [ { params => '&order=hotness' } ], }
		);

		# Menu entry 'Search Artists'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_FRIENDS_SEARCH'), type => 'search',
			url  => \&tracksHandler, passthrough => [ { type => 'users', parser => \&_parseFriends, params => '&order=hotness' } ] }
		);
		
		# Menu entry 'Tags'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_TAGS'), type => 'search',   
			url  => \&tracksHandler, passthrough => [ { type => 'tags', params => '&order=hotness' } ], }
		);

		# Menu entry 'Playlists'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_PLAYLIST_SEARCH'), type => 'search',
			url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists, params => '&order=hotness'  } ] }
		);

		# Menu entry to enter an URL manually
		push(@$callbacks, 
			{ name => string('PLUGIN_SQUEEZECLOUD_URL'), type => 'search', url  => \&urlHandler, }
		);

	} else {
		push(@$callbacks, 
			{ name => string('PLUGIN_SQUEEZECLOUD_LOGIN'), type => 'text' }
		);
	}

    # Add the menu entries from the menu array. It is responsible for calling 
    # the correct method (url) and passing any parameters.
	$callback->($callbacks);
	
	$log->debug('toplevel ended.');
}

# Always end with a 1 to make Perl happy
1;
