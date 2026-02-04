# A SoundCloud plugin for Lyrion music server #

This is a Lyrion Music Server (LMS) (a.k.a Squeezebox server) plugin to play tracks from SoundCloud.
It uses `ffmpeg` to transcode the SoundCloud stream.
To install, use the settings page of Lyrion Media Server.
Go to the _Plugins_ tab, scroll down to _3rd party plugins_ and select SoundCloud.
Press the _Apply_ button and restart LMS.

After installation, log in to your SoundCloud account via _Settings_ > _Advanced_ > _SoundCloud_

The plugin is included as a default third party resource. It is retrieved from this
GitHub repository. It is also possible to directly include
the repository XML as an additional repository. For the release version, include

    https://danielvijge.github.io/SqueezeCloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/SqueezeCloud/public-dev.xml

The development version might be broken at times.

## ffmpeg ##

`ffmpeg` must be installed to transcode the SoundCloud HLS stream to a stream that can be played directly by LMS.
On Debian Linux this can be installed like this:

    sudo apt install ffmpeg

When using the official Docker image, refer to the documentation how to install `ffmpeg` every time a new version is pulled.

The type of transcoding can be configured via _Settings_ > _Advanced_ > _File Types_.
Available options are flac, pmc, or mp3. Transcoding to mp3 also requires `lame` to be installed.

## SSL support ##

You need SSL support in Perl for this plugin (SoundCloud links are all over HTTPS), so you will need to install some SSL development headers on your server before installing this plugin.

You can do that on Debian Linux (Raspian, Ubuntu, Mint etc.) like this:

    sudo apt install libssl-dev
    sudo perl -MCPAN -e 'install IO::Socket::SSL'
    sudo systemctl restart lyrionmusicserver.service

And on Red Hat Enterprise Linux (Fedora, CentOS, etc.) like this:

    sudo yum -y install openssl-devel
    sudo perl -MCPAN -e 'install IO::Socket::SSL'
    sudo systemctl restart lyrionmusicserver.service

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
