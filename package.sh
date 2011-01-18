mkdir build
cp -R A*/ build
SVNVERSION=`svn info | grep Revision |  awk '{print $2}'`

sed -i "s/\/revision\//$SVNVERSION/g" ./build/Apache-CrowdAuth/lib/Apache/CrowdAuth.pm ./build/Atlassian-Crowd/lib/Atlassian/Crowd.pm 
cd build
zip -r ../apache-crowd-connector-rev$SVNVERSION.zip A*/
rm -Rf ../build
