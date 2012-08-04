package TestDNS;

use 5.010001;
use Test::Nginx::Socket -Base;
use JSON::XS;

use constant {
    TYPE_A => 1,
    TYPE_CNAME => 5,
    TYPE_AAAA => 28,
    CLASS_INTERNET => 1,
};

sub encode_name ($);
sub encode_ipv4 ($);
sub encode_ipv6 ($);

sub Test::Base::Filter::dns {
    my ($filter, $code) = @_;

    my $t = eval $code;
    if ($@) {
        die "failed to evaluate code $code: $@\n";
    }

    my $s = '';

    my $id = $t->{id} // 0;

    $s .= pack("n", $id);
    #warn "id: ", length($s), " ", encode_json([$s]);

    my $qr = $t->{qr} // 1;

    my $opcode = $t->{opcode} // 1;

    my $aa = $t->{aa} // 0;

    my $tc = $t->{tc} // 0;
    my $rd = $t->{rd} // 1;
    my $ra = $t->{ra} // 1;
    my $rcode = $t->{rcode} // 0;

    my $flags = ($qr << 15) + ($opcode << 11) + ($aa << 10) + ($tc << 9) + ($rd << 8) + ($ra << 7) + $rcode;
    #warn sprintf("flags: %b", $flags);

    $flags = pack("n", $flags);
    $s .= $flags;

    #warn "flags: ", length($flags), " ", encode_json([$flags]);

    my $answers = $t->{answer} // [];
    if (!ref $answers) {
        $answers = [$answers];
    }

    my $qdcount = $t->{qdcount} // 1;
    my $ancount = $t->{ancount} // scalar @$answers;
    my $nscount = 0;
    my $arcount = 0;

    $s .= pack("nnnn", $qdcount, $ancount, $nscount, $arcount);

    my $qname = encode_name($t->{qname} // "");

    #warn "qname: ", length($qname), " ", encode_json([$qname]);

    $s .= $qname;

    my $qs_type = $t->{qtype} // TYPE_A;
    my $qs_class = $t->{qclass} // CLASS_INTERNET;

    $s .= pack("nn", $qs_type, $qs_class);

    for my $ans (@$answers) {
        my $name = encode_name($ans->{name} // "");
        my $type = $ans->{type};
        my $class = $ans->{class};
        my $ttl = $ans->{ttl};
        my $rdlength = $ans->{rdlength};
        my $rddata = $ans->{rddata};

        my $ipv4 = $ans->{ipv4};
        if (defined $ipv4) {
            my ($data, $len) = encode_ipv4($ipv4);
            $rddata //= $data;
            $rdlength //= $len;
            $type //= TYPE_A;
            $class //= CLASS_INTERNET;
        }

        my $ipv6 = $ans->{ipv6};
        if (defined $ipv6) {
            my ($data, $len) = encode_ipv6($ipv6);
            $rddata //= $data;
            $rdlength //= $len;
            $type //= TYPE_AAAA;
            $class //= CLASS_INTERNET;
        }

        my $cname = $ans->{cname};
        if (defined $cname) {
            $rddata //= encode_name($cname);
            $rdlength //= length $rddata;
            $type //= TYPE_CNAME;
            $class //= CLASS_INTERNET;
        }

        $type //= 0;
        $class //= 0;
        $ttl //= 0;

        #warn "rdlength: $rdlength, rddata: ", encode_json([$rddata]), "\n";

        $s .= $name . pack("nnNn", $type, $class, $ttl, $rdlength) . $rddata;
    }

    return $s;
}

sub encode_ipv4 ($) {
    my $txt = shift;
    my @bytes = split /\./, $txt;
    return pack("CCCC", @bytes), 4;
}

sub encode_ipv6 ($) {
    my $txt = shift;
    my @groups = split /:/, $txt;
    my $nils = 0;
    my $nonnils = 0;
    for my $g (@groups) {
        if ($g eq '') {
            $nils++;
        } else {
            $nonnils++;
            $g = hex($g);
        }
    }

    my $total = $nils + $nonnils;
    if ($total > 8 ) {
        die "Invalid IPv6 address: too many groups: $total: $txt";
    }

    if ($nils) {
        my $found = 0;
        my @new_groups;
        for my $g (@groups) {
            if ($g eq '') {
                if ($found) {
                    next;
                }

                for (1 .. 8 - $nonnils) {
                    push @new_groups, 0;
                }

                $found = 1;

            } else {
                push @new_groups, $g;
            }
        }

        @groups = @new_groups;
    }

    if (@groups != 8) {
        die "Invalid IPv6 address: $txt: @groups\n";
    }

    #warn "IPv6 groups: @groups";

    return pack("nnnnnnnn", @groups), 16;
}

sub encode_name ($) {
    my $name = shift;
    $name =~ s/([^.]+)\.?/chr(length($1)) . $1/ge;
    $name .= "\0";
    return $name;
}

1