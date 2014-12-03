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
	return (preferences('plugin.squeezecloud'), qw(apiKey playmethod));
}

# Always end with a 1 to make Perl happy
1;
