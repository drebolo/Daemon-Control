package Daemon::Control;
use warnings;
use strict;
use vars qw| $AUTOLOAD |;
use POSIX qw| _exit setsid setuid setgid getuid getgid |;
use File::Spec;

our $VERSION = '0.001000'; # 0.1.0
$VERSION = eval $VERSION;

my @accessors = qw| pid color_map name code program program_args 
    uid path gid scan_name stdout_file stderr_file pid_file fork data 
    lsb_start lsb_stop lsb_sdesc lsb_desc |;

sub new {
    my ( $class, $args ) = @_;
    my $self = bless { _color_map => { red => 31, green => 32 } }, $class;

    for my $accessor ( @accessors ) {
        if ( exists $args->{$accessor} ) {
            $self->{"_$accessor"} = delete $args->{$accessor};
        }
    }
    die "Unknown arguments to the constructure: " . join( " ", keys %$args )
        if keys( %$args );

    return $self;
}

sub _double_fork {
    my ( $self ) = @_;
    my $pid = fork();

    if ( $pid == 0 ) { # Child, launch the process here.
        setsid(); # Become the process leader.
        my $new_pid = fork();
        if ( $new_pid == 0 ) { # Our double fork.
            setgid( $self->gid ) if $self->gid;
            setuid( $self->uid ) if $self->uid;
            open( STDIN, "<", File::Spec->devnull );
            if ( $self->stdout_file ) {
                open STDOUT, ">>", $self->stdout_file
                    or die "Failed to open STDOUT to " . $self->stdout_file , ": $!";
            }
            if ( $self->stderr_file ) {
                open STDOUT, ">>", $self->stderr_file
                    or die "Failed to open STDERR to " . $self->stderr_file . ": $!";
            }

            # New Program Stuff.
            if ( ref $self->program eq 'CODE' ) {
                $self->program->( @{$self->program_args || []} );
            } else {
                exec ( $self->program, @{$self->program_args || [ ]} )
                    or die "Failed to exec " . $self->program . " " 
                        . join( " ", @{$self->program_args} ) . ": $!";
            }
        } elsif ( not defined $new_pid ) {
            print STDERR "Cannot fork.\n";
        } else {
            $self->pid( $new_pid );
            $self->write_pid;
            _exit 0;
        }
    } elsif ( not defined $pid ) { # We couldn't fork.  =(
        print STDERR "Cannot fork.\n";
    } else { # In the parent, $pid = child's PID, return it.
        waitpid( $pid, 0 );
    }
    return $self;
}

sub _fork {
    my ( $self ) = @_;
    my $pid = fork();

    if ( $pid == 0 ) { # Child, launch the process here.
        if ( ref $self->program eq 'CODE' ) {
            $self->program->( @{$self->program_args || []} );
        } else {
            exec ( $self->program, @{$self->program_args || [ ]} )
                or die "Failed to exec " . $self->program . " " 
                    . join( " ", @{$self->program_args} ) . ": $!";
        }
        _exit 0;
    } else { # In the parent, $pid = child's PID, return it.
        $self->pid( $pid );
        $self->write_pid;
        #waitpid( $pid, 0 );
    }
    return $self;
}

sub write_pid {
    my ( $self ) = @_;
    open my $sf, ">", $self->pid_file
        or die "Failed to write " . $self->pid_file . ": $!";
    print $sf $self->pid;
    close $sf;
    return $self;
}

sub read_pid {
    my ( $self ) = @_;
    open my $lf, "<", $self->pid_file 
        or die "Failed to read " . $self->pid_file . ": $!";
    my $pid = do { local $/; <$lf> };
    close $lf;
    $self->pid( $pid );
    return $pid;
}

sub pid_running {
    my ( $self ) = @_;

    $self->read_pid;

    return 0 unless kill 0, $self->pid;
    #return kill 0, shift->pid;

    if ( $self->scan_name ) {
        open my $lf, "-|", "ps", "-p", $self->pid, "-o", "command="
            or die "Failed to get pipe to ps for scan_name.";
        while ( my $line = <$lf> ) {
            return 1 if $line =~ $self->scan_name;
        }
        return 0;
    }
    # Scan name wasn't used, testing normal PID.
    return kill 0, $self->pid;
}

sub pretty_print {
    my ( $self, $message, $color ) = @_;

    $color ||= "green"; # Green is no color.
    my $code = $self->color_map->{$color} ||= "32"; # Green is invalid.
    printf( "%-49s %30s\n", $self->name, "\033[$code" ."m[$message]\033[0m" );
}

# Callable Functions

sub do_start {
    my ( $self ) = @_;

    # Make sure the PID file exists.
    if ( ! -f $self->pid_file ) {
        $self->pid( "_" ); # Make PID invalid.
        $self->write_pid();
    }
    
    # Duplicate Check
    $self->read_pid;
    if ( $self->pid && $self->pid_running ) {
        $self->pretty_print( "Duplicate Running", "red" );
        exit 1;
    }

    if ( ! $self->fork ) {
        warn "Defaulting to fork ( set fork => 1, or fork => 2 )";
        $self->_fork;
    } else {
        $self->_double_fork if $self->fork == 2;
        $self->_fork if $self->fork == 1;
    }
    $self->pretty_print( "Started" );
}

sub do_stop {
    my ( $self ) = @_;

    $self->read_pid;
    if ( $self->pid && $self->pid_running ) {
        my $tried = 0;
        while ( $self->pid_running ) {
            kill INT => $self->pid if $tried == 0;
            kill TERM => $self->pid if $tried == 1 or $tried == 2;
            kill KILL => $self->pid if $tried == 3;
            $tried++;
            sleep 1;
        }
        if ( $self->pid_running ) {
            $self->pretty_print( "Failed to Stop", "red" );
            exit 1;
        }
        $self->pretty_print( "Stopped" );
        exit 0;
    } else {
        $self->pretty_print( "Not Running", "red" );
        exit 0;
    }
}

sub do_restart {
    my ( $self ) = @_;
    $self->read_pid;

    if ( $self->pid_running ) {
        $self->do_stop;
    }
    $self->do_start;
}

sub do_status {
    my ( $self ) = @_;
    $self->read_pid;

    if ( $self->pid && $self->pid_running ) {
        $self->pretty_print( "Running" );
        exit 0;
    } else {
        $self->pretty_print( "Not Running", "red" );
        exit 1;
    }
}

sub do_get_init_file {
    shift->dump_init_script;
}

# Magically create the accessors.

for my $method ( @accessors ) {
    my $accessor = sub {
        my $self = shift;
        $self->{"_$method"} = shift if @_;
        return $self->{"_$method"};
    };
    {
        no strict 'refs';
        no warnings 'redefine';
        *$method = $accessor;
    }
}

sub dump_init_script {
    my ( $self ) = @_;
    if ( ! $self->data ) {
        my $data;
        while ( my $line = <DATA> ) {
            last if $line =~ /^__END__$/;
            $data .= $line;
        }
        $self->data( $data );
    }

    $self->data( $self->run_template(
        $self->data,
        {
            NAME                => $self->name,
            REQUIRED_START      => $self->lsb_start,
            REQUIRED_STOP       => $self->lsb_stop,
            SHORT_DESCRIPTION   => $self->lsb_sdesc,
            DESCRIPTION         => $self->lsb_desc,
            SCRIPT              => $self->path ? $self->path : $0,
        }
    ));
    print $self->data;
}

sub run_template {
    my ( $self, $content, $config ) = @_;

    $content =~ s/\[% (.*?) %\]/$config->{$1}/g;

    return $content;
}

# Application Code.
sub run {
    my ( $self ) = @_;
   
    # Error Checking.
    if ( ( ! $self->code ) && ( ! $self->program ) ) {
        warn "Error: code or program MUST be defined.";
        exit 1;
    }
    if ( ! $self->pid_file ) {
        warn "Error: pid_file MUST be defined.";
        exit 1;
    }
    if ( ( ! $self->stdout_file ) || ( ! $self->stderr_file ) ) {
        warn "Warning: stdout_file and stderr_file not set.  Will not reopen to new files.";
    }
    if ( ! $self->name ) {
        warn "Error: name MUST be defined.";
    }

    my $called_with = shift @ARGV if @ARGV;
    my $action = "do_" . ($called_with ? $called_with : "" );

    if ( $self->can($action) ) {
        $self->$action;
    } elsif ( ! $called_with  ) {
        warn "Must be called with an action [start|stop|restart|status]";
        exit 1;
    } else {
        warn "Error: I don't know how to $called_with.";
        exit 1;
    }
    exit 0;
}

1;

__DATA__
#!/bin/sh

### BEGIN INIT INFO
# Provides:          [% NAME %]
# Required-Start:    [% REQUIRED_START %]
# Required-Stop:     [% REQUIRED_STOP %]
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: [% SHORT_DESCRIPTION %]
# Description:       [% DESCRIPTION %]
### END INIT INFO`


if [ -x [% SCRIPT %] ];
then
    [% SCRIPT %] $1
else
    echo "Requred program [% SCRIPT %] not found!"
    exit 1;
fi
__END__

=head1 NAME

Daemon::Control - Create init scripts in Perl

=head1 DESCRIPTION

Daemon::Control provides a library for creating init scripts in perl.
Your perl script just needs to set the accessors for what and how you
want something to run and the library takes care of the rest.

You can launch programs through the shell (/usr/sbin/my_program) or
launch Perl code itself into a daemon mode.  Single and double fork
methods are supported and in double-fork mode all the things you would
expect like reopening STDOUT/STDERR, switching UID/GID are supported.

=head1 SYNOPSIS

Write a program that describes the daemon:

    #!/usr/bin/perl
    use warnings;
    use strict;
    use Daemon::Control;

    Daemon::Control->new({
        name        => "My Daemon",
        lsb_start   => '$syslog $remote_fs',
        lsb_stop    => '$syslog',
        lsb_sdesc   => 'My Daemon Short',
        lsb_desc    => 'My Daemon controls the My Daemon daemon.',
        path        => '/home/symkat/etc/init.d/program',

        program     => '/home/symkat/bin/program',
        program_args => [ '-a', 'orange', '--verbose' ],

        pid_file    => '/tmp/mydaemon.pid',
        stderr_file => '/tmp/mydaemon.out',
        stdout_file => '/tmp/mydaemon.out',

        fork        => 2,

    })->run;

You can then call the program:

    /home/symkat/etc/init.d/program start

You can also make an LSB compatable init script:

    /home/symkat/etc/init.d/program get_init_file > /etc/init.d/program

=head1 CONSTRUCTURE

The constucture takes the following arguments.

=head2 name

The name of the program the daemon is controlling.  This will be used in
status messages "name [Started]" and the name for the LSB init script
that is generated.

=head2 program

This can be a coderef or the path to a shell program that is to be run.

$daemon->program( sub { ... } );

$daemon->program( "/usr/sbin/http" );


=head2 program_args

This is an array ref of the arguments for the program.  In the context
of a coderef being executed this will be given to the coderef as @_;

In the context of a shell program, it will be given as arguments to
be executed.

$daemon->program_args( [ 'foo', 'bar' ] );

$daemon->program_args( [ '--switch', 'argument' ] );

=head2 uid

If provided, the UID that the program will drop to when forked.  This is
ONLY supported in double-fork mode and will only work if you are running
as root.  This takes the numerical UID (grep user /etc/passwd )

$daemon->uid( 1001 );

=head2 gid

If provided, the GID that the program will drop to when forked.  This is
ONLY supported in double-fork mode and will only work if you are running
as root.  This takes the numerical GID ( grep group /etc/groups )

$daemon->gid( 1001 );

=head2 path

The path of the script you are using Daemon::Control in.  This will be used in 
the LSB file genration to point it to the location of the script.  If this is
not provided $0 will be used, which is likely to work only if you use the full
path to execute it when asking for the init script.

=head2 stdout_file

If provided stdout will be redirected to the given file.  This is only supported
in double fork more.

$daemon->stdout_file( "/tmp/mydaemon.stdout" );

=head2 stderr_file

If provided stderr will be redirected to the given file.  This is only supported
in double fork more.

$daemon->stderr_file( "/tmp/mydaemon.stderr" );

=head2 pid_file

The location of the PID file to use.  Warning: if using single-fork mode, it is
recommended to set this to the file which the daemon launching in single-fork
mode will put it's PID.  Failure to follow this will most likely result in status,
stop, and restart not working.

$daemon->pid_file( "/tmp/mydaemon.pid" );

=head2 fork

The mode to use for fork.  By default a double-fork will be used.

In double-fork, uid, gid, std*_file, and a number of other things are
supported.  A traditional double-fork is used and setsid is called.

In single-fork none of the above are called, and it is the responsiblity
of whatever you're forking to reopen files, associate with the init process
and do all that fun stuff.  This mode is recommended when the program you want
to control has it's own daemonizing code.  It is importand to note that the PID
file should be set to whatever PID file is used by the daemon.

$daemon->fork( 1 );

$daemon->fork( 2 ); # Default

=head2 scan_name

This provides an extra check to see if the program is running.  Normally
we only check that the PID listed in the PID file is running.  When given
a regular expression, we will also match the name of the program as shown
in ps.

$daemon->scan_name( qr|mydaemon| );

=head2 lsb_start

The value of this string is used for the 'Required-Start' value of
the generated LSB init script.  See L<http://wiki.debian.org/LSBInitScripts>
for more information.

$daemon->lsb_start( '$remote_fs $syslog' );

=head2 lsb_stop

The value of this string is used for the 'Required-Stop' value of
the generated LSB init script.  See L<http://wiki.debian.org/LSBInitScripts>
for more information.

$daemon->lsb_stop( '$remote_fs $syslog' );

=head2 lsb_sdesc

The value of this string is used for the 'Short-Description' value of
the generated LSB init script.  See L<http://wiki.debian.org/LSBInitScripts>
for more information.

$daemon->lsb_sdesc( 'Mah program...' );


=head2 lsb_desc

The value of this string is used for the 'Description' value of
the generated LSB init script.  See L<http://wiki.debian.org/LSBInitScripts>
for more information.

$daemon->lsb_desc( 'My program controls a thing that does a thing.' );

=head1 METHODS

=head2 run

This will make your program act as an init file, accepting input from
the command line.  Run will exit either 1 or 0, following LSB files on
exiting.  As such no code should be used after ->run is called.  Any code
in your file should be before this.

=head2 do_start

Is called when start is given as an argument.  Starts the forking, and
exits.

/usr/bin/my_program_launcher.pl start

=head2 do_stop

Is called when stop is given as an argument.  Stops the running program
if it can.

/usr/bin/my_program_launcher.pl stop

=head2 do_restart

Is called when restart is given as an argument.  Calls do_stop and do_start.

/usr/bin/my_program_launcher.pl restart

=head2 do_status

Is called when status is given as an argument.  Displays the status of the
program, basic on the PID file.

/usr/bin/my_program_launcher.pl status

=head2 do_get_init_file

Is called when get_init_file is given as an argument.  Dumps an LSB
compatable init file, for use in /etc/init.d/

/usr/bin/my_program_launcher.pl get_init_file

=head2 pretty_print

This is used to display status to the user.  It accepts a message, and a color.
It will default to green text, if no color is explictly given.  Only supports
red and green.

$daemon->pretty_print( "My Status", "red" );

=head2 write_pid

This will write the PID to the file in pid_file.

=head2 read_pid

This will read the PID from the file in pid_file and set it in pid.

=head2 pid

An accessor for the PID.  Set by read_pid, or when the program is started.

=head2 dump_init_script

A function to dump the LSB compatable init script.  Used by do_get_init_file.

=head1 AUTHOR

SymKat I<E<lt>symkat@symkat.comE<gt>> ( Blog: L<http://symkat.com/> )

=head2 CONTRIBUTORS

Matt S. Trout (mst) <mst@mst@shadowcat.co.uk>

=head1 COPYRIGHT

Copyright (c) 2012 the Daemon::Control L</AUTHOR> and L</CONTRIBUTORS> as listed above.

=head1 LICENSE 

This library is free software and may be distributed under the same terms as perl itself.

=head2 AVAILABILITY

