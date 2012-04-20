#!/usr/bin/env perl

use 5.010;
use strict;
use warnings;
use Getopt::Std;
use File::Copy;


# Ifdefs - class to track #ifdef's
package Ifdefs;
    sub new {
        my ($class, $is_header) = @_;
        return bless { guards => 0,
                       ifdefs => 0,
                       is_header => $is_header },
                   $class;
    }

    sub push {
        my ($self, $line) = @_;
        my $is_guard =  $line ~~ /^\s*#\s*if\w*\s*INCLUDED/
                     || $self->{is_header} && $self->{guards} == 0;
            # in the header file, the first #ifdef is always considered to be
            # an include guard, otherwise include guards should start with
            # word INCLUDED

        push @{$self->{ifdef_types}}, $is_guard;

        if ($is_guard) {
            $self->{guards}++;
        } else {
            $self->{ifdefs}++;
        }
    }

    sub pop {
        my $self = shift;
        my $is_guard = pop @{$self->{ifdef_types}};

        if ($is_guard) {
            $self->{guards}--;
        } else {
            $self->{ifdefs}--;
        }
    }

    sub top {
        my $self = shift;
        return $self->{ifdef_types}->[-1];
    }

    sub size {
        my $self = shift;
        return 0 unless $self->{ifdef_types};
        return @{$self->{ifdef_types}};
    }

    sub ifdefs {
        my $self = shift;
        return $self->{ifdefs};
    }


package main;

# version for Getopt
our $VERSION = '0.1';

# display help message, called indirectly from Getopt
sub HELP_MESSAGE {
    print <<"EOF";

Replace class forward declarations in C++ code with appropriate inclusion of
'forward declaration' headers.

synopsis:
    apply-bslfwd.pl [-c] c++-source-files*

options:
    -c  Run the script in 'check' mode to find out whether given source files
        contain any forward declarations that need to be replaced.  The source
        files remain unchanged.

    c++-source-files*
        C++ source files to process and replace class forward declaration in.

EOF
}

$Getopt::Std::STANDARD_HELP_VERSION = 1;

use constant {
    GUARD_PFX   => 'INCLUDED_BSLFWD_',
    INCLUDE_PFX => '#include <bslfwd_',
    INCLUDE_SFX => '.h>',
};

sub is_header {
    my $src = shift;
    return $src ~~ /\.h(h|pp|xx)?$/;  # *.h, *.hh, *.hpp, *.hxx
}

sub gen_fdecl {
    my ($out, $class, $generate_guards) = @_;
    my $include_line = INCLUDE_PFX . lc($class) . INCLUDE_SFX;
    my $fdecl_text;

    if ($generate_guards) {
        my $include_guard = GUARD_PFX . uc($class);
        $fdecl_text =<<"EOF";

#ifndef $include_guard
$include_line
#endif
EOF
    } else {
        $fdecl_text = "$include_line\n";
    }

    print $out $fdecl_text;
}

# read_src - read and analyze the source file for things like class forward declarations
# and included headers
sub read_src {
    my %args = @_;
    my $src = $args{src};
    my $is_header = $args{is_header};
    my $fdecl_lines = $args{fdecl_lines};
    my $fdecl_classes = $args{fdecl_classes};

    my $last_include_line;  # last included header after which more includes can be added
    my $last_include_line_locked = 0;
    my $bloomberglp_line;   # the line where namespace BloombergLP begins
    my $is_dualmode_file;   # this source file has #ifdef __cplusplus
    my $cur_line = 0;
    my $ifdefs = Ifdefs->new($is_header);
    my $expect_guards = $is_header;

    open my $fh, '<', $src
        or die $!;
    my @lines = <$fh>;

    for (@lines) {
        $cur_line++;

        given ($_) {
            when (/^\s*#\s*if(.*?__cplusplus)?/) {
                $ifdefs->push($_);
                if ($1) {
                    $is_dualmode_file = 1;
                }
            }
            when (/^\s*#\s*endif/) {
                $ifdefs->pop();
            }
            when (/^\s*#\s*include\s<(.*?)>/
                  && !$last_include_line_locked
                  && $ifdefs->ifdefs() == 0)
            {
                # found #include<...>
                $last_include_line = $cur_line;

                if ($expect_guards) {
                    given ($lines[$cur_line]) {
                        when (/^\s*#\s*endif/) {
                            # found #endif right after #include
                            $last_include_line = $cur_line + 1;
                        }
                        when (/^\s*#\s*define\s+INCLUDED/) {
                            # found #define INCLUDED...
                            # next should be #endif
                            if ($lines[$cur_line + 1] ~~ /^\s*#\s*endif/) {
                                $last_include_line = $cur_line + 2;
                            } else {
                                warn "warning: $src: $cur_line: unrecognized redundant include guard pattern\n";
                            }
                        }
                    }
                }
            }
            when (/^\s*(class|struct)\s+(bsl\w+?_\w+|bdema_Allocator)\s*;/) {
                # found forward declaration
                my $class = $2;

                # treat bdema_Allocator as bslma_Allocator
                $class = 'bslma_Allocator' if $class ~~ 'bdema_Allocator';

                # don't remove 'struct ...' forward declarations from what
                # appears to be a C header file
                if (!($is_dualmode_file && $1 ~~ 'struct')) {
                    $fdecl_lines->{$cur_line} = $_;
                    $fdecl_classes->{$class} = 1;
                }
            }
            when (/^\s*namespace\s+BloombergLP/ && !defined $bloomberglp_line) {
                # check if the previous line is empty
                if ($lines[$cur_line - 2] =~ /^\s*$/) {
                    $bloomberglp_line = $cur_line - 1;
                } else {
                    $bloomberglp_line = $cur_line;
                }
            }
            when (/^\s*(\w)/ && lc($1) ~~ $1 && !/_IDENT|char\s.*RCS/) {
                # not a # or // or some IDENT or RCS line
                $last_include_line_locked = 1;
            }
        }
    }

    warn "warning: $src: $cur_line: unbalanced #if/#endif\n"
        unless $ifdefs->size() == 0;

    if ($is_dualmode_file && defined $bloomberglp_line) {
        return $bloomberglp_line - 1;
    } elsif (defined $last_include_line) {
        return $last_include_line;
    } elsif (defined $bloomberglp_line) {
        return $bloomberglp_line - 1;
    } else {
        return undef;
    }
}

# write_tgt - produce a target file with forward declarations of bsl classes replaced
# with included bslfwd headers
sub write_tgt {
    my %args = @_;
    my $src = $args{src};
    my $tgt = $args{tgt};
    my $generate_guards = $args{generate_guards};
    my $insert_headers_at = $args{insert_headers_at};
    my $fdecl_lines = $args{fdecl_lines};
    my $fdecl_classes = $args{fdecl_classes};
    my $insert_empty_line;

    my $cur_line = 0;
    open my $in, '<', $src
        or die $!;
    open my $out, '>', $tgt
        or die $!;

    while (<$in>) {
        $cur_line++;

        if (defined $insert_headers_at && $cur_line == $insert_headers_at) {
            print $out $_;

            # generate forward declaration includes
            for my $class (keys %$fdecl_classes) {
                gen_fdecl($out, $class, $generate_guards);
            }

            $insert_empty_line = 1;  # insert an empty line after forward declaration headers if needed

        } elsif (defined $fdecl_lines->{$cur_line}
                || (/^\s*$/ && defined $fdecl_lines->{$cur_line - 1}))
        {
            # skip the forward declaration and the empty line after it
        } else {
            if ($insert_empty_line) {
                $insert_empty_line = undef;

                if (!/^\s*$/) {
                    print $out "\n";
                }
            }

            print $out $_;
        }
    }
}

sub replace {
    my ($what, $with) = @_;
    move($with, $what);
}

sub applyfwd {
    my $src = shift;
    my $is_header = is_header($src);
    my %fdecl_lines;            # lines on which forward declarations appear
    my %fdecl_classes;          # collected forward declaration classes

    my $insert_headers_at = read_src(src           => $src,
                                     is_header     => $is_header,
                                     fdecl_lines   => \%fdecl_lines,
                                     fdecl_classes => \%fdecl_classes);

    if (%fdecl_classes) {
        warn "warning: $src: failed to insert forward declaration headers, the result file is likely incorrect\n"
            unless defined $insert_headers_at;

        my $tgt = $src . '.new';
        write_tgt(src               => $src,
                  tgt               => $tgt,
                  generate_guards   => $is_header,
                  insert_headers_at => $insert_headers_at,
                  fdecl_lines       => \%fdecl_lines,
                  fdecl_classes     => \%fdecl_classes);

        replace($src, $tgt);
    }
}

sub checkfwd {
    my $src = shift;
    my $is_header = is_header($src);
    my %fdecl_lines;            # lines on which forward declarations appear
    my %fdecl_classes;          # collected forward declaration classes

    read_src(src           => $src,
             is_header     => $is_header,
             fdecl_lines   => \%fdecl_lines,
             fdecl_classes => \%fdecl_classes);

    if (%fdecl_lines) {
        my @line_numbers = sort { $a<=>$b } keys %fdecl_lines;
        for (@line_numbers) {
            my $line = $fdecl_lines{$_};
            print "$src:$_: $line"
        }
    }
}

sub main {
    my %opt;
    getopts('c', \%opt);

    if ($opt{c}) {
        for (@ARGV) {
            checkfwd($_);
        }
    } else {
        for (@ARGV) {
            applyfwd($_);
        }
    }
}

__PACKAGE__->main() unless caller;
