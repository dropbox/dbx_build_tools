# This script reads the OpenSSL meta-build system configuration output
# and converts into constants for the BUILD file.

use strict;

my %perlasm;

print "LIBCRYPTO_SRCS = [";
foreach (sort @{$unified_info{sources}->{libcrypto}}) {
    my $src = $unified_info{sources}->{$_}->[0];
    print '    "' . $src . '",';
    if (exists($unified_info{generate}->{$src})) {
        $perlasm{$src} = ${unified_info{generate}->{$src}};
    }
}
print "]\n";
print "LIBSSL_SRCS = [";
foreach (sort @{$unified_info{sources}->{libssl}}) {
    my $src = $unified_info{sources}->{$_}->[0];
    print '    "' . $src . '",';
}
print "]\n";
print "OPENSSL_APP_SRCS = [";
foreach (sort @{$unified_info{sources}->{"apps/openssl"}}, @{$unified_info{sources}->{"apps/libapps.a"}}) {
    my $src = $unified_info{sources}->{$_}->[0];
    print '    "' . $src . '",';
}
print "]\n";
print "PERLASM_OUTS = [";
foreach (sort keys %perlasm) {
    print '    "' . $_ . '",';
}
print "]\n";
print "PERLASM_TOOLS = [";
foreach (sort values %perlasm) {
    print '    "' . @{$_}[0] . '",';
}
print "]\n";
print 'PERLASM_GEN = """';
foreach (sort keys %perlasm) {
    my $generation = $perlasm{$_};
    my $cmdline = join(" ", @{$generation}[1,]);
    $cmdline =~ s/\$\(PERLASM_SCHEME\)/$target{perlasm_scheme}/g;
    print "CC=\$(CC) perl \$(location @{$generation}[0]) " . $cmdline . " \$(location $_);";
}
print '"""';
print;
print "OPENSSL_DEFINES = [";
foreach (sort @{$target{defines}}, @{$config{defines}}, @{$config{lib_defines}}, @{$config{openssl_other_defines}}) {
    print '    "-D', $_, '",';
}
print "]\n";
