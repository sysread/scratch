#!/usr/bin/env perl
# A simple greeter that says hello in multiple languages.
use strict;
use warnings;

my %greetings = (
    en => "Hello",
    es => "Hola",
    fr => "Bonjour",
    de => "Hallo",
    ja => "Konnichiwa",
);

my $lang = shift || "en";
my $name = shift || "World";

die "Unknown language: $lang\n" unless exists $greetings{$lang};
printf "%s, %s!\n", $greetings{$lang}, $name;
