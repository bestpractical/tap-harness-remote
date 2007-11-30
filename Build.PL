use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'TAP::Harness::Remote',
    license             => 'perl',
    dist_author         => 'Alex Vandiver <alexmv@bestpractical.com>',
    dist_version_from   => 'lib/TAP/Harness/Remote.pm',
    requires => {
        'Test::More' => 0,
        'version'    => 0,
        'TAP::Harness' => 3.04,
    },
    add_to_cleanup      => [ 'TAP-Harness-Remote-*' ],
);

$builder->create_build_script();
