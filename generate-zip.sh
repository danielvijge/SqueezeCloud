set -x

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')

cd ..
zip -r SqueezeCloud-$VERSION.zip SqueezeCloud -x \*.zip \*.sh \*.git\* \*README\* \*webauth\*
SHA=$(shasum SqueezeCloud-$VERSION.zip | awk '{print $1;}')

cat <<EOF > public.xml
<extensions>
	<details>
		<title lang="EN">SqueezeCloud Plugin</title>
	</details>
	<plugins>
		<plugin name="SqueezeCloud" version="$VERSION" minTarget="7.5" maxTarget="*">
			<title lang="EN">SqueezeCloud</title>
			<desc lang="EN">Browse, search and play urls from soundcloud</desc>
			<url>http://rsiebert.github.io/SqueezeCloud/SqueezeCloud-$VERSION.zip</url>
			<link>https://github.com/rsiebert/SqueezeCloud</link>
			<sha>$SHA</sha>
			<creator>Robert Siebert, Daniel Vijge, Robert Gibbon, David Blackman</creator>
		</plugin>
	</plugins>
</extensions>
EOF

