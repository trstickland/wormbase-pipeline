#!/usr/local/bin/perl

srand( time() ^ ($$ + ($$ << 15)));

while ( <> ) {
    chomp;
    ($name,$email)  = (/^(\S+)\s+(\S+)/);
    push(@namespace,$name);
    $email{$name} = $email;
    $randspace{$name} = rand;
}

foreach $entry (@namespace) { $val{$entry} = rand 10000; }

@namespace = sort { $val{$a}<=>$val{$b} } @namespace;

$previous_entry = @namespace[$#namespace];

foreach $entry ( @namespace) {

    $pair{$previous_entry} = $entry;
    $previous_entry = $entry;
}


# send the mails
foreach $entry ( @namespace) {

#    open (MAIL,"| Mail -s \"Beware of geeks bearing gifts - a message from Santa\" $email{$entry}");
#    print MAIL "\nThank you for being a Secret Santa\n\nThis message was generated by a perl script\n";
#    print MAIL "with a random number generator. Your secret santa recipient is <$email{$pair{$entry}}>\n";
#    print MAIL "\n\nDO NOT LOSE THIS MESSAGE as there is no record at all of who is chosen for Secret Santa!\n";
#    close (MAIL);

    open (MAIL,"| mailx -s \"WormBase Secret Santa!\" $email{$entry}");
    print MAIL "\nThank you for being a Secret Santa\n\nThis message was generated by a perl script\n";
    print MAIL "with a random number generator. Your secret santa recipient is <$email{$pair{$entry}}>\n";
    print MAIL "\n\nDO NOT LOSE THIS MESSAGE as there is no record at all of who is chosen for Secret Santa!\n";
    close (MAIL);


}


