# This script reads the OpenSSL meta-build system configuration output
# and converts into JSON that is used to render the BUILD file.

use strict;

print "{";

# Make a Json list
sub list {
    my $name = shift;
    my $inner = shift;
    return qq(   "$name": [\n$inner\n   ])
}

# Make a list from sources
sub list_srcs {
    my $name = shift;
    my @srcs = map { qq(    "$_") }
               map { $unified_info{sources}->{$_}->[0] }
               sort @_;
    return list($name, join(",\n", @srcs));
}

my $libcrypto_srcs = list_srcs("libcrypto_srcs", @{$unified_info{sources}->{libcrypto}});
my $libssl_srcs = list_srcs("libssl_srcs", @{$unified_info{sources}->{libssl}});
my $app_srcs = list_srcs("openssl_app_srcs", @{$unified_info{sources}->{"apps/openssl"}});
my $libapp_srcs = list_srcs("libapp_srcs", @{$unified_info{sources}->{"apps/libapps.a"}});

my %perlasm;
foreach (@{$unified_info{sources}->{libcrypto}}) {
    my $src = $unified_info{sources}->{$_}->[0];
    if (exists($unified_info{generate}->{$src})) {
        $perlasm{$src} = ${unified_info{generate}->{$src}};
    }
}

sub perl_asm {
    my $generation = $perlasm{$_};
    my $cmdline = join(" ", @{$generation}[1,]);
    $cmdline =~ s/\$\(PERLASM_SCHEME\)/$target{perlasm_scheme}/g;

    return qq(    {
      "generator": "@{$generation}[0]",
      "cmdline": "$cmdline",
      "output": "$_"
    })
}

my @asm_decls = map { perl_asm } sort keys %perlasm;
my $asm_srcs = list("asm_srcs", join(",\n", @asm_decls));

my @defs = map { qq(    "$_") }
           sort @{$target{defines}}, @{$config{defines}}, @{$config{lib_defines}}, @{$config{openssl_other_defines}};
my $defines = list("openssl_defines", join(",\n", @defs));

print join(",\n", ($libcrypto_srcs, $libssl_srcs, $app_srcs, $libapp_srcs, $asm_srcs, $defines));

# TODO - cflags, cxxflags, bn_opts, lib_cppflags?, enable, asflags?
print "}";
