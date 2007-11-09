package Jifty::DBI::Tisql;

use strict;
use warnings;

use base qw(Parse::BooleanLogic);

use Regexp::Common qw(delimited);
my $re_delim  = qr{$RE{delimited}{-delim=>qq{\'\"}}};
my $re_field  = qr{[a-zA-Z][a-zA-Z0-9_]*};
my $re_column = qr{$re_field(?:\.$re_field)*};
my $re_sql_op_bin = qr{!?=|<>|>=?|<=?|(?:NOT )?LIKE}i;
my $re_sql_op_un  = qr{IS (?:NOT )?NULL}i;
my $re_value = qr{$re_delim|[0-9.]+};

sub parse_query {
    my $self = shift;
    my $string = shift;

    my $query_tree = $self->as_array(
        $string,
        operand_cb => sub { return $self->split_condition( $_[0] ) },
    );
    #use Data::Dumper; warn Dumper( $query_tree );
    $self->apply_query_tree( $query_tree );
    return $query_tree;
}

sub apply_query_tree {
    my $self = shift;
    my $tree = shift;

    my $collection = $self->{'collection'};

    my $ea = shift || 'AND';
    $collection->open_paren('tisql');
    foreach my $element ( @$tree ) {
        unless ( ref $element ) {
            $ea = $element;
            next;
        }
        elsif ( ref $element eq 'ARRAY' ) {
            $self->apply_query_tree( $element, $ea );
            next;
        }
        elsif ( ref $element ne 'HASH' ) {
            die "wrong query tree";
        }

        my %limit = (
            subclause        => 'tisql',
            entry_aggregator => $ea,
            operator         => $element->{'op'},
        );
        if ( ref $element->{'lhs'} ) {
            my ($alias, $column) = $self->resolve_join( @{ $element->{'lhs'} } );
            @limit{qw(alias column)} = ($alias, $column->name);
        } else {
            die "left hand side must be always column specififcation";
        }
        if ( ref $element->{'rhs'} ) {
            my ($alias, $column) = $self->resolve_join( @{ $element->{'rhs'} } );
            @limit{qw(quote_value value)} = (0, $alias .'.'. $column->name );
        } else {
            $limit{'value'} = $element->{'rhs'};
        }

        $collection->limit( %limit );
    }
    $collection->close_paren('tisql');
}

sub resolve_join {
    my $self = shift;
    my @chain = @_;
    if ( @chain == 1 ) {
        return 'main', $chain[0];
    }

    my $collection = $self->{'collection'};

    my $last_column = pop @chain;
    my $last_alias = 'main';

    foreach my $column ( @chain ) {
        my $name = $column->name;

        my $classname = $column->refers_to;
        unless ( $classname ) {
            die "column '$name' of is not a reference";
        }

        if ( UNIVERSAL::isa( $classname, 'Jifty::DBI::Collection' ) ) {
            my $item = $classname->new( handle => $collection->_handle )->new_item;
            my $right_alias = $collection->new_alias( $item );
            $collection->join(
                type    => 'left',
                alias1  => $last_alias,
                column1 => 'id',
                alias2  => $right_alias,
                column2 => $column->by || 'id',
            );
            $last_alias = $right_alias;
        }
        elsif ( UNIVERSAL::isa( $classname, 'Jifty::DBI::Record' ) ) {
            my $item = $classname->new( handle => $collection->_handle );
            my $right_alias = $collection->new_alias( $item );
            $collection->join(
                type    => 'left',
                alias1  => $last_alias,
                column1 => $name,
                alias2  => $right_alias,
                column2 => $column->by || 'id',
            );
            $last_alias = $right_alias;
        }
        else {
            die "Column '$name' refers to '$classname' which is not record or collection";
        }
    }
    return ($last_alias, $last_column);
}

sub split_condition {
    my $self = shift;
    my $string = shift;

    if ( $string =~ /^($re_column)\s*($re_sql_op_bin)\s*($re_value)$/o ) {
        my ($lhs, $op, $rhs) = ($self->find_column($1), $2, $3);
        if ( $rhs =~ /^$re_delim$/ ) {
            $rhs =~ s/^["']//g;
            $rhs =~ s/["']$//g;
        }
        return { lhs => $lhs, op => $op, rhs => $rhs };
    }
    elsif ( $string =~ /^($re_column)\s*($re_sql_op_un)$/o ) {
        my ($lhs, $op, $rhs) = ($self->find_column($1), $2, $3);
        ($op, $rhs) = split /\s*(?=null)/i, $op;
        return { lhs => $lhs, op => $op, rhs => $rhs };
    }
    elsif ( $string =~ /^($re_column)\s*($re_sql_op_bin)\s*($re_column)$/o ) {
        return { lhs => $self->find_column($1), op => $2, rhs => $self->find_column($3) };
    }
    else {
        die "$string is not a tisql condition";
    }
}

sub find_column {
    my $self = shift;
    my $string = shift;

    my @res;

    my @names = split /\./, $string;
    my $item = $self->{'collection'}->new_item;
    while ( my $name = shift @names ) {
        my $column = $item->column( $name );
        die "$item has no column '$name'" unless $column;

        push @res, $column;
        return \@res unless @names;

        my $classname = $column->refers_to;
        unless ( $classname ) {
            die "column '$name' of $item is not a reference";
        }

        if ( UNIVERSAL::isa( $classname, 'Jifty::DBI::Collection' ) ) {
            $item = $classname->new( handle => $self->{'collection'}->_handle )->new_item;
        }
        elsif ( UNIVERSAL::isa( $classname, 'Jifty::DBI::Record' ) ) {
            $item = $classname->new( handle => $self->{'collection'}->_handle )
        }
        else {
            die "Column '$name' refers to '$classname' which is not record or collection";
        }
    }

    return \@res;
}





1;
