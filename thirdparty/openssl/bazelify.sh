#!/bin/bash -e
# Downloads openssl, configures it, and creates a the file BUILD file.

version=1.1.1h
mydir=$(realpath $(dirname "$0"))
rm -fr openssl-$version
curl -f "https://www.openssl.org/source/openssl-$version.tar.gz" | tar xz
pushd openssl-$version
# Define a new configuration that hard disables all dlopening.
cat <<'E_O_F' >dbx.conf
(
    'dbx-linux-x86_64' => {
        inherit_from    => [ 'linux-x86_64' ],
        dso_scheme     => undef,
    }
);
E_O_F
# no-afalgeng because we don't need afalgeng.
# no-dynamic-engine to prevent loading shared libraries at runtime.
./Configure "--config=dbx.conf" dbx-linux-x86_64 no-afalgeng no-dynamic-engine
make include/openssl/opensslconf.h include/crypto/bn_conf.h include/crypto/dso_conf.h apps/progs.h
echo -e "# BEGIN GENERATED CODE (see $(basename $0))\n" > "$mydir/BUILD.openssl"
echo -e "OPENSSL_VERSION = \"$version\"\n" >> "$mydir/BUILD.openssl"
echo -e "OPENSSLCONF_H = \"\"\"$(grep ^# include/openssl/opensslconf.h)\"\"\"\n" >> "$mydir/BUILD.openssl"
echo -e "BN_CONF_H = \"\"\"$(grep ^# include/crypto/bn_conf.h)\"\"\"\n" >> "$mydir/BUILD.openssl"
echo -e "DSO_CONF_H = \"\"\"$(grep ^# include/crypto/dso_conf.h)\"\"\"\n" >> "$mydir/BUILD.openssl"
echo -e "APPS_PROGS_H = \"\"\"$(< apps/progs.h)\"\"\"\n" >> "$mydir/BUILD.openssl"
perl -I. -l -Mconfigdata "$mydir/extract_srcs.pl" >> "$mydir/BUILD.openssl"
echo "# END GENERATED CODE\n" >> "$mydir/BUILD.openssl"
cat "$mydir/BUILD.openssl.tail" >> "$mydir/BUILD.openssl"
popd
