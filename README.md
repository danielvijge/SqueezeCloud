# A SoundCloud plugin for Logitech SqueezeBox media server #

This is a Logitech Media Server (LMS) (a.k.a Squeezebox server) plugin to play
tracks from SoundCloud. To install, use the settings page of Logitech Media server.
Go to the _Plugins_ tab, scroll down to _Third party source_ and select _SqueezeCloud_.
Press the _Apply_ button and restart LMS.

After installation, configure it via _Settings_ > _Advanced_ > _SqueezeCloud_

The plugin is included as a default third party resource. It is distributed via my
[personal repository](https://server.vijge.net/squeezebox/) This third party repository
is synced with the repository XML files on GitHub. It is also possible to directly include
the repository XML from GitHub. For the release version, include
    
    https://danielvijge.github.io/SqueezeCloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/SqueezeCloud/public-dev.xml

## SSL support ##

You need SSL support in Perl for this plugin (SoundCloud links are all over HTTPS), so you will need to install some SSL development headers on your server before installing this plugin.

You can do that on Debian Linux (Raspian, Ubuntu, Mint etc.) like this:

	sudo apt-get install libssl-dev
	sudo perl -MCPAN -e 'install IO::Socket::SSL'
	sudo service logitechmediaserver restart

And on Red Hat Enterprise Linux (Fedora, CentOS, etc.) like this:

    sudo yum -y install openssl-devel
    sudo perl -MCPAN -e 'install IO::Socket::SSL'
    sudo service logitechmediaserver restart

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
