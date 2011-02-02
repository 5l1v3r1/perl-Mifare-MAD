#!/usr/bin/perl
use warnings;
use strict;

use RFID::Libnfc::Reader;
use RFID::Libnfc::Constants;
use File::Slurp;
use Digest::MD5 qw(md5_hex);
use Getopt::Long::Descriptive;

use Data::Dump qw(dump);

my ($opt,$usage) = describe_options(
	'%c %c [dump_with_keys]',
	[ 'write=s',	'write dump to card' ],
	[ 'debug|d',	'show debug dumps' ],
	[ 'help|h',		'usage' ],
);
print $usage->text, exit if $opt->help;

my $debug = $ENV{DEBUG} || 0;
our $keyfile = shift @ARGV;
our ( $tag, $uid, $card_key_file );

sub write_card_dump;

my $r = RFID::Libnfc::Reader->new(debug => $debug);
if ($r->init()) {
    warn "reader: %s\n", $r->name;
    my $tag = $r->connect(IM_ISO14443A_106);

    if ($tag) {
        $tag->dump_info;
    } else {
        warn "No TAG";
        exit -1;
    }

	$uid = sprintf "%02x%02x%02x%02x", @{ $tag->uid };

	$card_key_file = "cards/$uid.key";
	$keyfile ||= $card_key_file;

	if ( -e $keyfile ) {
		warn "# loading keys from $keyfile";
	    $tag->load_keys($keyfile);
		warn "## _keys = ", dump($tag->{_keys}) if $debug;
	}

    $tag->select if ($tag->can("select")); 

	my $card;

	print STDERR "reading $uid blocks ";
    for (my $i = 0; $i < $tag->blocks; $i++) {
        if (my $data = $tag->read_block($i)) {
            # if we are dumping an ultralight token, 
            # we receive 16 bytes (while a block is 4bytes long)
            # so we can skip next 3 blocks
            $i += 3 if ($tag->type eq "ULTRA");
			$card .= $data;
			print STDERR "$i ";
		} elsif ( $tag->error =~ m/auth/ ) {
			warn $tag->error,"\n";

			# disconnect from reader so we can run mfoc
			RFID::Libnfc::nfc_disconnect($r->{_pdi});

			print "Dump this card with mfoc? [y] ";
			my $yes = <STDIN>; chomp $yes;
			exit unless $yes =~ m/y/i || $yes eq '';

			my $file = "cards/$uid.key";
			unlink $file;
			warn "# finding keys for card $uid with: mfoc -O $file\n";
			exec "mfoc -O $file" || die $!;
        } else {
            die $tag->error."\n";
        }
    }
	print STDERR "done\n";

	my $out_file = write_card_dump $tag => $card;

	if ( $opt->write ) {
		read_file $opt->write;
		print STDERR "writing $uid block ";
		foreach my $block ( 0 .. $tag->blocks ) {
			my $offset = 0x10 * $block;
			my $data = substr($card,$offset,0x10);
			$tag->write_block( $block, $data );
			print STDERR "$block ";
			my $verify = $tag->read_block( $block );
			print STDERR $verify eq $data ? "OK " : "ERROR ";
		}
		print STDERR "done\n";
		unlink $card_key_file;
		$out_file = write_card_dump $tag => $card;
	} else {
		# view dump
		my $txt_file = $out_file;
		$txt_file =~ s/\.mfd/.txt/ || die "can't change extension of $out_file to txt";
		system "./mifare-mad.pl $out_file > $txt_file";
		$ENV{MAD} && system "vi $txt_file";
	}
}

sub write_card_dump {
	my ( $tag, $card ) = @_;

	# re-insert keys into dump
	my $keys = $tag->{_keys} || die "can't find _keys";
	foreach my $i ( 0 .. $#$keys ) {
		my $o = $i * 0x40 + 0x30;
		last if $o > length($card);
		$card
			= substr($card, 0,   $o) . $keys->[$i]->[0]
			. substr($card, $o+6, 4) . $keys->[$i]->[1]
			. substr($card, $o+16)
			;
		warn "# sector $i keys re-inserted at $o\n" if $debug;
	}

	if ( my $padding = 4096 - length($card) ) {
		warn "# add $padding bytes up to 4k dump (needed for keys loading)\n" if $debug;
		$card .= "\x00" x $padding;
	}

	my $md5 = md5_hex($card);
	my $out_file = "cards/$uid.$md5.mfd";
	if ( -e $out_file ) {
		warn "$out_file allready exists, not overwriting\n";
	} else {
		write_file $out_file, $card;
		warn "$out_file ", -s $out_file, " bytes key: $card_key_file\n";
	}

	if ( ! -e $card_key_file ) {
		my $source = $out_file;
		$source =~ s{^cards/}{} || die "can't strip directory from out_file";
		symlink $source, $card_key_file || die "$card_key_file: $!";
		warn "$card_key_file symlink created as default key for $uid\n";
	}

	return $out_file;
}
