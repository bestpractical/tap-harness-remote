package TAP::Harness::Remote;

our $VERSION = '0.01';

use warnings;
use strict;
use Carp;

use base 'TAP::Harness';
use constant config_path => "$ENV{HOME}/.remote_test";
use File::Path;
use Cwd;
use YAML;

=head1 NAME

TAP::Harness::Remote - Run tests on a remote server

=head1 SYNOPSIS

    prove -l --state=save,slow --harness TAP::Harness::Remote t/*.t

=head1 DESCRIPTION

Sometimes you want to run tests on a remote testing machine, rather
than your local development box.  C<TAP::Harness::Remote> allows you
so reproduce entire directory trees on a remote server via C<rsync>,
and spawn the tests remotely.  It also supports round-robin
distribution of tests across multiple remote testing machines.

=head1 USAGE

C<TAP::Harness::Remote> synchronizes a local directory to the remote
testing server.  All tests that you wish to run remotely must be
somewhere within this "local testing root" directory.  You should
configure where this directory is by creating or editing your
F<~/.remote_test> file:

    ---
    ssh: /usr/bin/ssh
    local: /path/to/local/testing/root/
    user: username
    host: remote.testing.host.example.com
    root: /where/to/place/local/root/on/remote/
    perl: /usr/bin/perl
    master: 1
    ssh_args:
      - -x
      - -S
      - '~/.ssh/master-%r@%h:%p'

See L</CONFIGURATION AND ENVIRONMENT> for more details on the
individual configuration options.

Once your F<~/.remote_test> is configured, you can run your tests
remotely, using:

    prove -l --harness TAP::Harness::Remote t/*.t

Any paths in C<@INC> which point inside your local testing root are
rewritten to point to the equivilent path on the remote host.  This is
especially useful if you are testing a number of inter-related
modules; by placing all of them all under the local testing root, and
adding all of their C<lib/> paths to your C<PERL5LIB>, you can ensure
that the remote machine always tests your combination of the modules,
not whichever versions are installed on the remote host.

Note that for irritating technical reasons (your CWD has already been
resolved), your local root cannot contain symlinks to directories.
This means you may need to rearrange your directory structure slightly
to set up the appropriate local testing root.

If you farm of remote hosts, you may change the C<host> configuration
variable to be an array reference of hostnames.  Tests will be
distributed in a round-robin manner across the hosts.  Each host will
run as many tests in parallel as you specified with C<-j>.

Especially when running tests in parallel, it is highly suggested that
you use the standard L<TAP::Harness> C<--state=save,slow> option, as
this ensures that the slowest tests will run first, reducing your
overall test run time.

=head1 METHODS

=head2 new

Overrides L<TAP::Harness/new> to load the local configuration, and add
the necessary hooks for when tests are actually run.

=cut

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    $self->load_remote_config;
    die
        "Local testing root (@{[$self->remote_config('local')]}) doesn't exist\n"
        unless -d $self->remote_config("local");

    my $change
        = File::Spec->abs2rel( Cwd::cwd, $self->remote_config("local") );
    die
        "Current path isn't inside of local testing root (@{[$self->remote_config('local')]})\n"
        if $change =~ /^\.\./;

    die "Testing host not defined\n"
        unless grep { defined and not /\.example\.com$/ }
        @{ $self->remote_config("host") };

    die
        "Can't find or execute ssh command: @{[$self->remote_config('ssh')]}\n"
        unless -e $self->remote_config("ssh")
        and -x $self->remote_config("ssh");

    $ENV{HARNESS_PERL} = $self->remote_config("ssh");

    $self->jobs( $self->jobs * @{ $self->remote_config("host") } );

    $self->callback( before_runtests => sub { $self->rsync(@_) } );
    $self->callback( parser_args     => sub { $self->change_switches(@_) } );
    return $self;
}

=head2 config_path

Returns the path to the configuration file; this is usually
C<$ENV{HOME}/.remote_test>.

=head2 default_config

Returns, as a hashref, the default configuration.  See
L</CONFIGURATION>.

=cut

sub default_config {
    return {
        user     => "smoker",
        host     => "smoke-server.example.com",
        root     => "/home/smoker/remote-test/$ENV{USER}/",
        perl     => "/home/smoker/bin/perl",
        local    => "/home/$ENV{USER}/remote-test/",
        ssh      => "/usr/bin/ssh",
        ssh_args => [ "-x", "-S", "~/.ssh/master-%r@%h:%p" ],
        master   => 1,
    };
}

=head2 load_remote_config

Loads and canonicalizes the configuration.  Writes and uses the
default configuration (L</default_config>) if the file does not exist.

=cut

sub load_remote_config {
    my $self = shift;
    unless ( -e $self->config_path and -r $self->config_path ) {
        YAML::DumpFile( $self->config_path, $self->default_config );
    }
    $self->{remote_config} = YAML::LoadFile( $self->config_path );

    # Make sure paths end with slashes, for rsync
    $self->{remote_config}{root} .= "/"
        unless $self->{remote_config}{root} =~ m|/$|;
    $self->{remote_config}{local} .= "/"
        unless $self->{remote_config}{local} =~ m|/$|;

    # Host should be an arrayref
    $self->{remote_config}{host} = [ $self->{remote_config}{host} ]
        unless ref $self->{remote_config}{host};

    # Ditto ssh_args
    $self->{remote_config}{ssh_args}
        = [ split ' ', $self->{remote_config}{ssh_args} ]
        unless ref $self->{remote_config}{ssh_args};
}

=head2 remote_config KEY

Returns the configuration value set fo the given C<KEY>.

=cut

sub remote_config {
    my $self = shift;
    $self->load_remote_config unless $self->{remote_config};
    return $self->{remote_config}->{ shift @_ };
}

=head2 userhost [HOST]

Returns a valid C<user@host> string; host is taken to be the first
known host, unless provided.

=cut

sub userhost {
    my $self = shift;
    my $userhost = @_ ? shift : $self->remote_config("host")->[0];
    $userhost = $self->remote_config("user") . "\@" . $userhost
        if $self->remote_config("user");
    return $userhost;
}

=head2 start_masters

Starts the ssh master connections, if support for them is enabled.
Otherwise, does nothing.  See the man page for C<ssh -M> for more
information about master connections.

=cut

sub start_masters {
    my $self = shift;
    return unless $self->remote_config("master");

    for my $host ( @{ $self->remote_config("host") } ) {
        my $userhost = $self->userhost($host);
        my $pid      = fork;
        die "Fork failed: $!" unless $pid >= 0;
        if ( not $pid ) {
            exec $self->remote_config("ssh"),
                @{ $self->remote_config("ssh_args") }, "-M", "-N", $userhost;
            die "Starting of master SSH connection failed";
        }
        $self->{ssh_master}{$userhost} = $pid;
    }
    sleep 2;
}

=head2 rsync

Starts the openssh master connections if need be (see
L</start_masters>), then C<rsync>'s over the entire local root.
Additionally, rewrites the local PERL5LIB path such that any
directories which point into the local root are included in the remote
PERL5LIB as well.

=cut

sub rsync {
    my $self = shift;
    $self->start_masters;

    for my $host ( @{ $self->remote_config("host") } ) {
        my $userhost = $self->userhost($host);
        my $return   = system(
            qw!rsync -avz --delete!,
            qq!--rsh!,
            $self->remote_config("ssh")
                . " @{$self->remote_config('ssh_args')}",
            $self->remote_config("local"),
            "$userhost:" . $self->remote_config("root")
        );
        die "rsync to $userhost failed" if $return;
    }

    if ( my $lib = $ENV{PERL5LIB} ) {
        my @lib    = split( /:/, $lib );
        my $local  = $self->remote_config("local");
        my $remote = $self->remote_config("root");
        $ENV{PERL5LIB} = join( ":", map { s/^$local/$remote/; $_ } @lib );
    }
}

=head2 DESTROY

Tears down the ssh master connections, if they were started.

=cut

sub DESTROY {
    my $self = shift;
    return unless $self->remote_config("master");
    for my $userhost ( keys %{ $self->{ssh_master} || {} } ) {
        next unless kill 0, $self->{ssh_master}{$userhost};
        system $self->remote_config("ssh"), @{ $self->remote_config("ssh_args") }, "-O",
            "exit", $userhost;
    }
}

=head2 change_switches

Changes the switches around, such that the remote perl is called, via
ssh.

=cut

sub change_switches {
    my ( $self, $args, $test ) = @_;

    my $local  = $self->remote_config("local");
    my $remote = $self->remote_config("root");

    $ENV{PERL5LIB} ||= '';

    $ENV{PERL5LIB} =~ s/^(lib:){1,}/lib:/;
    my @other = grep { not /^-I/ } @{ $args->{switches} };
    my @inc = map { s/^-I$local/-I$remote/; $_ }
        grep {/^-I/} @{ $args->{switches} };

    my $change = File::Spec->abs2rel( Cwd::cwd, $local );
    my $host = $self->remote_config("host")
        ->[ $self->{hostno}++ % @{ $self->remote_config("host") } ];
    my $userhost = $self->userhost($host);
    $args->{switches} = [
        @{ $self->remote_config("ssh_args") }, $userhost,
        "cd",                                  $remote . $change,
        "&&",                                  "PERL5LIB='$ENV{PERL5LIB}'",
        $self->remote_config("perl"),          @other,
        @inc
    ];
}

=head1 CONFIGURATION AND ENVIRONMENT

Configuration is done via the file C<~/.remote_test>, which is a YAML
file.  Valid keys are:

=over

=item user

The username to use on the remote connection.

=item host

The host to connect to.  If this is an array reference, tests will be
distributed, round-robin fashion, across all of the hosts.  This does
also incur the overhead of rsync'ing to each host.

=item root

The remote testing root.  This is the place where the local root will
be C<rsync>'d to.

=item local

The local testing root.  All files under this will be C<rsync>'d to
the remote server.  All tests to be run remotely must be within this
root.

=item perl

The path to the C<perl> binary on the remote host.

=item ssh

The path to the local C<ssh> binary.

=item ssh_args

Either a string or an array reference of arguments to pass to ssh.
Suggested defaults include C<-x> and C<-S ~/.ssh/master-%r@%h:%p>

=item master

If a true value is given for this, will attempt to use OpenSSH master
connections to reduce the overhead of making repeated connections to
the remote host.

=back

=head1 DEPENDENCIES

A recent enough TAP::Harness build; 3.03 or later should suffice.
Working copies of OpenSSH and rsync.

=head1 BUGS AND LIMITATIONS

Aborting tests using C<^C> may leave dangling processes on the remote
host.

Please report any bugs or feature requests to
C<bug-tap-harness-remote@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 AUTHOR

Alex Vandiver  C<< <alexmv@bestpractical.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007-2008, Best Practical Solutions, LLC.  All rights
reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut

1;
