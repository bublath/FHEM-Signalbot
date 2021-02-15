##############################################
# $Id:1.2$
# Simple Interface to Signal CLI running as Dbus service
# Author: Adimarantis
# License: GPL
# Credits to FHEM Forum Users Quantum (SiSi Module) and Johannes Viegener (Telegrambot Module) for code fragments and ideas
# Requires signal_cli (https://github.com/AsamK/signal-cli) and Net::DBus to work
package main;

use strict;
use warnings;
use Net::DBus;
use Net::DBus::Reactor;
use Scalar::Util qw(looks_like_number);
use File::Temp qw( tempfile tempdir );
use Text::ParseWords;
use Encode;

eval "use Net::DBus;1" or my $NETDBus = "Net::DBus";
eval "use Net::DBus::Reactor;1" or my $NETDBusReactor = "Net::DBus::Reactor";

my %sets = (
  "send" => "textField",
  "refreshGroups" => "noArg",
  "reinit" => "noArg",
  "saveContacts" => "noArg",
  "setContact" => "textField",
  "createGroup" => "textField",		#Call updategroups with empty group parameter, mandatory name and optional avatar picture
  "invite" => "textField",			#Call updategroups with mandatory group name and mandatory list of numbers to join
  "block" => "textField",			#Call setContactBlocked or setGroupBlocked (one one at a time)
  "unblock" => "textField",			#Call setContactBlocked or setGroupBlocked (one one at a time)
  "updateGroup" => "textField"		#Call updategroups to rename a group and/or set avatar picture
 );

my $sep="##"; #Seperator used for splitting message content passed from Child to Parent
my $Signalbot_devicename="";

sub Signalbot_Initialize($) {
  my ($hash) = @_;

  $hash->{DefFn}     = 	"Signalbot_Define";
  $hash->{InitFn}  	 =  'Signalbot_Init';
  $hash->{AttrFn}    = 	"Signalbot_Attr";
  $hash->{SetFn}     = 	"Signalbot_Set";
  $hash->{NotifyFn}  =  'Signalbot_Notify';
  $hash->{ReadFn}    = 	"Signalbot_Read";
  $hash->{StateFn}   =  "Signalbot_State";
  $hash->{GetFn}     = 	"Signalbot_Get";
  $hash->{UndefFn}   = 	"Signalbot_Undef";
  $hash->{AttrList}  = 	"IODev do_not_notify:1,0 ignore:1,0 showtime:1,0 ".
												"defaultPeer: ".
												"poll_interval: ".
												"allowedPeer ".
												"babblePeer ".
												"babbleDev ".
												"babbleExclude ".
												"$readingFnAttributes";
}
################################### Todo: Set or Attribute for Mode? Other sets needed?
sub Signalbot_Set($@) {					#

  my ( $hash, $name, @args ) = @_;
  
#  Log3 $hash->{NAME}, 5, "Signalbot_Set $name: called "; 

  ### Check Args
  my $numberOfArgs  = int(@args);
  return "Signalbot_Set: No cmd specified for set" if ( $numberOfArgs < 1 );

  my $cmd = shift @args;

  if (!exists($sets{$cmd}))  {
    my @cList;
    foreach my $k (keys %sets) {
      my $opts = undef;
      $opts = $sets{$k};

      if (defined($opts)) {
        push(@cList,$k . ':' . $opts);
      } else {
        push (@cList,$k);
      }
    } # end foreach
    return "Signalbot_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
  } # error unknown cmd handling

	if ( $cmd eq "refreshGroups") {
		#Gruppen neu einlesen
		my $ret;
		$ret=Signalbot_Refreshgroups($hash) if ($init_done);
		return $ret;
	} elsif ( $cmd eq "setContact") {
		if (int(@args)<2 ) {
			return "Usage: set ".$hash->{NAME}." setContact <number> <nickname>";
		} else {
			my $number = shift @args;
			my $nickname = join (" ",@args);
			my $ret=Signalbot_setContactName($hash,$number,$nickname);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "createGroup") {
		if (int(@args)<1 || int(@args)>2 ) {
			return "Usage: set ".$hash->{NAME}." createGroup <group name> &[path to thumbnail]";
		} else {
			my $ret=Signalbot_updateGroup($hash,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "block" || $cmd eq "unblock") {
		if (int(@args)!=1) {
			return "Usage: set ".$hash->{NAME}." ".$cmd." <group name>|<contact>";
		} else {
			my $name=shift @args;
			my $ret=Signalbot_setBlocked($hash,$name,($cmd eq "block"?1:0));
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "updateGroup") {
		if (int(@args)<1 || int(@args)>3 ) {
			return "Usage: set ".$hash->{NAME}." updateGroup <group name> #[new name] &[path to thumbnail]";
		} else {
			my $ret=Signalbot_updateGroup($hash,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "invite") {
		if (int(@args) < 2 ) {
			return "Usage: set ".$hash->{NAME}." invite <group name> <contact1> [<contact2] ...]";
		} else {
			my $groupname = shift @args;
			my $ret=Signalbot_invite($hash,$groupname,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "send") {
		return "Usage: set ".$hash->{NAME}." send [@<Recipient1> ... @<RecipientN>] [#<GroupId1> ... #<GroupIdN>] [&<Attachment1> ... &<AttachmentN>] [<Text>]" if ( int(@args)==0); 

		my @recipients = ();
		my @groups = ();
		my @attachments = ();
		my $message = "";
		#To allow spaces in strings, join string and split it with parse_line that will honor spaces embedded by double quotes
		my $fullstring=join(" ",@args);
		my $bExclude=AttrVal($hash->{NAME},"babbleExclude",undef);
		if ($bExclude && $fullstring =~ /$bExclude(.*)/s) {  #/s required so newlines are included in match
			#Extra utf Encoding marker)
			$fullstring=encode_utf8($1);
			Log3 $hash->{NAME}, 3 , $hash->{NAME}.": Extra UTF8 encoding of:$fullstring:\n";
		}
		eval { $fullstring=decode_utf8($fullstring); };
			Log3 $hash->{NAME}, 3 , $hash->{NAME}.": Error from decode" if $@;
			
		Log3 $hash->{NAME}, 3 , $hash->{NAME}.": Before parse:$fullstring:\n";
		my $tmpmessage = $fullstring =~ s/\\n/\x0a/r;
		my @args=parse_line(' ',0,$tmpmessage);
		
		while(my $curr_arg = shift @args){
			if($curr_arg =~ /^\@([^#].*)$/){	#Compatbility with SiSi - also allow @# as groupname
				push(@recipients,$1);
			}elsif($curr_arg =~ /^\@#(.*)$/){ 	#Compatbility with SiSi - also allow @# as groupname
				push(@groups,$1);
			}elsif($curr_arg =~ /^#(.*)$/){
				push(@groups,$1);
			}elsif($curr_arg =~ /^\&(.*)$/){
				push(@attachments,$1);
			}else{
				unshift(@args,$curr_arg);
				last;
			}

		}
		my $defaultPeer=AttrVal($hash->{NAME},"defaultPeer",undef);
		return "Not enough arguments. Specify a Recipient, a GroupId or set the defaultPeer attribute" if( (int(@recipients) == 0) && (int(@groups) == 0) && (!defined $defaultPeer) );

		#Check for embedded fhem/perl commands
		my $err;
		($err, @recipients) = SignalBot_replaceCommands($hash,@recipients);
		if ($err) { return $err; }
		($err, @groups) = SignalBot_replaceCommands($hash,@groups);
		if ($err) { return $err; }
		($err, @attachments) = SignalBot_replaceCommands($hash,@attachments);
		if ($err) { return $err; }
		
		#Am Schluss eine Schleife über die Attachments und alle die mit /tmp/signalbot anfangen löschen (unlink)

		if ((defined $defaultPeer) && int(@recipients) == 0 && int(@groups) == 0) {

			my @peers = split(/,/,$defaultPeer);
			while(my $curr_arg = shift @peers){
				if($curr_arg =~ /^#/){
					push(@groups,$curr_arg);
				} else {
					push(@recipients,$curr_arg);
				}
			}
		}
		return "Specify either a message text or an attachment" if((int(@attachments) == 0) && (int(@args) == 0));

		$message = join(" ", @args);
		if (@attachments>0) {
			#create copy in /tmp to mitigate incomplete files and relative paths in fhem
			my @newatt;
			foreach my $file (@attachments) {
				if ( -e $file ) {
					if ($file =~ /[tmp\/signalbot]/) {
						$file =~ /^.*?\.([^.]*)?$/;
						my $type = $1;
						my $tmpfilename="/tmp/signalbot".gettimeofday().".".$type;
						copy($file,$tmpfilename);
						push @newatt, $tmpfilename;
					} else {
						push @newatt, $file;
					}
				} else {
					return "File not found: $file";
				}
			}
			@attachments=@newatt;
		}

		#Send message to individuals (bulk)
		if (@recipients > 0) {
			my $ret=Signalbot_sendMessage($hash,join(",",@recipients),join(",",@attachments),$message);
			return $ret if defined $ret;
		}
		if (@groups > 0) {
		#Send message to groups (one at time)
			while(my $currgroup = shift @groups){
				my $ret=Signalbot_sendGroupMessage($hash,$currgroup,join(",",@attachments),$message);
				return $ret if defined $ret;
			}
		}
		#Remove the tempfiles
		foreach my $file (@attachments) {
			if ($file =~ /tmp\/signalbot/) {
				unlink $file;
			}
		}
	} elsif ( $cmd eq "reinit") {
		my $ret = Signalbot_setup($hash);
		$hash->{STATE} = $ret if defined $ret;
	} elsif ( $cmd eq "saveContacts") {
		Log3 $hash->{NAME}, 5, "saveContacts to reading";  
		my $contacts=$hash->{helper}{contacts};
		my $clist="";
		my $first=1;
		if (defined $contacts) {
			foreach my $key (keys %{$contacts}) {
				my $val=$contacts->{$key};
				if ($first) { $first=0; } else { $clist.=","; }
				$clist.="$key=$val";
			}
			readingsSingleUpdate($hash, 'contactList', $clist,0);
		}
	}
  	return undef;
}
################################### 
sub Signalbot_Get($@) {
	#Nothing to be done here, let all updates run asychroniously with timers
	return undef;
}

sub Signalbot_message_callback {
	my ($hash, $timestamp, $source, $groupID, $message, $attachments) = @_;

	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message Callback";

	if ($message eq "") {
		#Empty messages happens e.g. if someone leaves a group - ignore
		return;
	}

	my @groups=@$groupID;
	my $tmp="";
	foreach (@groups) {
		$tmp.=$_." " if defined $_;
	} 	
	my $group=Signalbot_translateGroup($hash,trim($tmp));
	
	$tmp="";
	my @att=@$attachments;
	foreach (@att) {
		$tmp.= $_." " if defined $_;
	}	
	
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 5, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}
	
	my $senderRegex = quotemeta($sender);
	#Also check the untranslated sender names in case these were used in allowedPeer instead of the real names
	my $sourceRegex = quotemeta($source);
	my $groupIdRegex = quotemeta($group);
	my $allowedPeer = AttrVal($hash->{NAME},"allowedPeer",undef);
	
	if(!defined $allowedPeer || $allowedPeer =~ /^.*$senderRegex.*$/ || $allowedPeer =~ /^.*$sourceRegex.*$/ || ($groupIdRegex ne "" && $allowedPeer =~ /^.*$groupIdRegex.*$/)) {
		#Copy previous redings to keep history of on message
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "prevMsgTimestamp", ReadingsVal($hash->{NAME}, "msgTimestamp", undef)) if defined ReadingsVal($hash->{NAME}, "msgTimestamp", undef);
		readingsBulkUpdate($hash, "prevMsgText", ReadingsVal($hash->{NAME}, "msgText", undef)) if defined ReadingsVal($hash->{NAME}, "msgText", undef);
		readingsBulkUpdate($hash, "prevMsgSender", ReadingsVal($hash->{NAME}, "msgSender", undef)) if defined ReadingsVal($hash->{NAME}, "msgSender", undef);
		readingsBulkUpdate($hash, "prevMsgGroupName", ReadingsVal($hash->{NAME}, "msgGroupName", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupName", undef);
		readingsBulkUpdate($hash, "prevMsgGroupId", ReadingsVal($hash->{NAME}, "msgGroupId", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupId", undef);
		readingsBulkUpdate($hash, "prevMsgAttachment", ReadingsVal($hash->{NAME}, "msgAttachment", undef)) if defined ReadingsVal($hash->{NAME}, "msgAttachment", undef);
		readingsEndUpdate($hash, 0);

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "msgAttachment", trim($tmp));
		readingsBulkUpdate($hash, "msgTimestamp", strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
		readingsBulkUpdate($hash, "msgText", $message);
		readingsBulkUpdate($hash, "msgSender", $sender);
		readingsBulkUpdate($hash, "msgGroupName", $group);
		readingsEndUpdate($hash, 1);

		my $bDevice=AttrVal($hash->{NAME},"babbleDev",undef);
		my $bPeer=AttrVal($hash->{NAME},"babblePeer",undef);
		my $bExclude=AttrVal($hash->{NAME},"babbleExclude",undef);
		
		if ($bExclude && $message =~ /$bExclude/) {
			Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message matches BabbleExclude, skipping BabbleCall";
			return;
		}
		
		#Just pick one sender in den Priority: group, named contact, number, babblePeer
		my $replyPeer=undef;
		$replyPeer=$sourceRegex if defined $sourceRegex;
		$replyPeer=$senderRegex if defined $senderRegex;
		$replyPeer="#".$groupIdRegex if defined $groupIdRegex;
		
		#Activate Babble integration, only if sender or sender group is in babblePeer 
		if (defined $bDevice && defined $bPeer && defined $replyPeer) {
			if ($bPeer =~ /^.*$senderRegex.*$/ || $bPeer =~ /^.*$sourceRegex.*$/ || ($groupIdRegex ne "" && $bPeer =~ /^.*$groupIdRegex.*$/)) {
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": Calling Babble for $message ($replyPeer)";
				my $rep=Babble_DoIt($bDevice,$message,$replyPeer);
			}
		}
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message from $sender : $message processed";
	} else {
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message from $sender : $message ignored due to allowedPeer";
	}
}

sub Signalbot_receipt_callback {
	my ($hash, $timestamp, $source) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Signalbot_receive_callback $timestamp $source ";
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 5, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsgRecipient", $sender);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
	readingsEndUpdate($hash, 0);
}

sub Signalbot_sync_callback {
	my ($hash,$timestamp, $source, $string1, $array1, $string2, $array2) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}."Signalbot: Signalbot_sync_callback $timestamp $source";
	my $tmp="";
	my @arr1=@$array1;
	foreach (@arr1) {
		$tmp.=$_." " if defined $_;
	} 

	my @arr2=@$array2;
	foreach (@arr2) {
		$tmp.= $_." " if defined $_;
	} 	
}

sub Signalbot_disconnect($@) {
    my ($hash) = @_;
	my $name=$hash->{NAME};
	eval { 
		if ($hash->{helper}{dbus} ) {
			#Cleanup helper structures to allow reinit
			my $reactor=$hash->{helper}{dreactor};
			if (defined $reactor) {
				my $timer=$hash->{helper}{timer};
				if (defined $timer) {
					$reactor->remove_timeout($timer);
					delete $hash->{helper}{timer};
				}
				delete $hash->{helper}{dreactor};
			}
			my $object=$hash->{helper}{dobject};
			if (defined $object) {
				my $msignal=$hash->{helper}{msignal};
				if (defined $msignal) {
					$object->disconnect_from_signal($msignal);
					delete $hash->{helper}{msignal};
				}
				my $ssignal=$hash->{helper}{ssignal};
				if (defined $ssignal) {
					$object->disconnect_from_signal($ssignal);
					delete $hash->{helper}{ssignal};
				}
				my $rsignal=$hash->{helper}{rsignal};
				if (defined $rsignal) {
					$object->disconnect_from_signal($rsignal);
					delete $hash->{helper}{rsignal};
				}
				delete $hash->{helper}{dobject};
			}
			delete $hash->{helper}{service} if defined $hash->{helper}{dservice};
			delete $hash->{helper}{dbus} if defined $hash->{helper}{dbus};
		}
	}; 
	if ($@) {
		Log3 $name, 5, "Error in disconnect:".$@;
	}
	Log3 $name, 5, "Disconnected and cleaned up";
}

sub Signalbot_setup($@){
    my ($hash) = @_;
	my $name=$hash->{NAME};
	if (defined $hash->{helper}{dbus}) {
		#Reinitialize everything to avoid double callbacks and other issues
		Signalbot_disconnect($hash);
	}	
	delete $hash->{helper}{contacts};
	my ($bus, $service, $object, $reactor);
	eval {
		$bus = Net::DBus->system;
		return "Error getting Dbus" unless defined $bus;
		$hash->{helper}{dbus}=$bus;
		$service = $bus->get_service("org.asamk.Signal");
		return "Error getting Dbus service" unless defined $service;
		$hash->{helper}{dservice}=$service;
		$object = $service->get_object("/org/asamk/Signal");
		return "Error getting Dbus object" unless defined $object;
		$hash->{helper}{dobject}=$object;	
		$reactor=Net::DBus::Reactor->main();	
		return "Error getting Dbus reactor" unless defined $reactor;
		$hash->{helper}{dreactor}=$reactor;
	}; 
	if ($@) {
		#invalidate so there are no additional error
		Log3 $name, 3, $hash->{NAME}.": Error while initializing Dbus:".$@;
		$hash->{helper}{dbus}=undef;
		return "Exception while setting up Dbus - see syslog for details";
	}

	#Always check if callbacks are already defined to avoid getting multiple callbacks
	$hash->{helper}{msignal} = $object->connect_to_signal("MessageReceived", 
		sub { Signalbot_message_callback($hash,@_);} ) 
		unless defined $hash->{helper}{msignal} ;
	Log3 $name, 5, $hash->{NAME}.": Added message signal ".$hash->{helper}{msignal};
	$hash->{helper}{ssignal} = $object->connect_to_signal("SyncMessageReceived", 
		sub { Signalbot_sync_callback($hash,@_);} ) 
		unless defined $hash->{helper}{ssignal} ;
	Log3 $name, 5, $hash->{NAME}.": Added sync signal ".$hash->{helper}{ssignal};
	$hash->{helper}{rsignal} = $object->connect_to_signal("ReceiptReceived", 
		sub { Signalbot_receipt_callback($hash,@_);} ) 
		unless defined $hash->{helper}{rsignal} ;
	Log3 $name, 5, $hash->{NAME}.": Added receipt signal ".$hash->{helper}{rsignal};

	#Set a very short timer that guarantees that the $reactor->step() function still immediately returns when there is nothing to do.
	$hash->{helper}{timer} = $reactor->add_timeout(1,
       Net::DBus::Callback->new(method => sub {
	      #Do nothing
		})) unless defined $hash->{helper}{timer}; 	
	my $count = 0;
	my $fds=undef;
    foreach (keys %{$reactor->{fds}->{read}}) {
	next unless $reactor->{fds}->{read}->{$_}->{enabled};
	$fds=$_;
	$count++;
    }
	return "Error getting Dbus filehandler" unless defined $fds;
	if ($count!=1) {
	Log3 $name, 5, "$name: Unexpected number of filehandles";
	}
	Log3 $name, 5, "$name: Initializing Dbus with filehandle $fds";
	$hash->{FD}=$fds;
    $selectlist{"$name.dbus"} = $hash;
	$hash->{STATE}="Connected";
	
	#Restore contactlist into internal hash
	my $clist=ReadingsVal($hash->{NAME}, "contactList",undef);
	if (defined $clist) {
		my @contacts=split(",",$clist);
		foreach my $val (@contacts) {
			my ($k,$v) = split ("=",$val);
			$hash->{helper}{contacts}{$k}=$v;
		}
	}
	return undef;
}

sub Signalbot_Read($@){
    my ($hash) = @_;
	my $reactor=$hash->{helper}{dreactor};
	return "Error Dbus rector not set" unless defined $reactor;
	#Set a timer to avoid that 

	$reactor->{running} = 1; #Otherwise step won't read anything and we have a endless loop calling this again
    $reactor->step(); #Step twice just in case there is more queued up. There is no way I know of to check if the queue is empty already
    $reactor->step();
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Read from Dbus done";
}

sub Signalbot_getContactName($@) {
    my ( $hash,$number) = @_;

	#check internal inventory
	my $contact=$hash->{helper}{contacts}{$number};

	#if not found, ask Signal
	if (!defined $contact || $contact eq "") {
		my $object=$hash->{helper}{dobject};
		return "Dbus not initialized" unless defined $object;
		eval {
			$contact = $object->getContactName($number);
		}; return "Error getting contact name:".$@ if $@ && "$@" ne '';
		#Add to internal inventory
		$hash->{helper}{contacts}{$number}=$contact;
	}
	if ($contact eq "") {return $number;}
	return $contact;
}

#Allow create only for new groups
sub Signalbot_updateGroup($@) {
    my ( $hash,@args) = @_;
	my $groupname = shift @args;
	if ($groupname =~ /^#(.*)/) {
		$groupname=$1;
	}
	my $rename;
	my $avatar;
	while (my $next = shift @args) {
		if ($next =~ /^#(.*)/) {
			$rename=$1;
		}
		if ($next =~ /^\&(.*)/) {
			$avatar=$1;
		}
	}
	if (defined $avatar) {
		return "Can't find file $avatar" unless ( -e $avatar);
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": updateGroup Avatar $avatar";
		my $size = -s $avatar;
		return "Please reduce the size of your group picture to <2MB" if ($size>2000000);
	}
	my @groupID=Signalbot_getGroup($hash,$groupname);
	#Rename case: Group has to exist
	if (defined $rename) {
		if (int(@groupID)==1) {
			return "Group $groupname does not exist";
		} else {
			Log3 $hash->{NAME}, 5, $hash->{NAME}.": renameGroup $groupname to $rename";
			$groupname=$rename;
		}
	}
	#Create case (no rename and no avatar): Group cannot exist
	if (!defined $rename && !defined $avatar) {
		return "Group $groupname already exists" if int(@groupID)>1;
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": createGroup $groupname";
	}
	if (int(@groupID)==1) {
		@groupID=();
	}
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;
	eval {
	#Disabling to set an avatar picture since that is always throwing in error currently
		my $ret = $object->updateGroup(\@groupID,$groupname,undef,$avatar);
		my @groupID = @$ret;
	}; return "Error updating group:".$@ if $@ && "$@" ne '';
	return Signalbot_Refreshgroups($hash);
}

sub Signalbot_invite($@) {
    my ( $hash,$groupname,@contacts) = @_;

	my @members=();
	while (@contacts) {
		my $contact=shift @contacts;
		my $number=Signalbot_translateContact($hash,$contact);
		return "Unknown Contact" unless defined $number;
		push @members,$number;
	}
	
	my @group=Signalbot_getGroup($hash,$groupname);
	return join(" ",@group) unless int(@group)>1;
	
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;

	eval {
		my $ret=$object->updateGroup(\@group,undef,\@members,undef);
		my @groupID = @$ret;
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": Invited ".join(",",@contacts)." to $groupname";
	}; return "Error in invite:".$@ if $@ && "$@" ne '';
	#reply does not matter (should be same groupID as the one sent)
	return undef;
}

sub Signalbot_setBlocked($@) {
    my ( $hash,$name,$blocked) = @_;
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;
	if ($name =~ /^#(.*)/) {
		my @group=Signalbot_getGroup($hash,$1);
		return join(" ",@group) unless int(@group)>1;
		eval {my $ret=$object->setGroupBlocked(\@group,$blocked);};
		return "Error blocking group:".$@ if $@ && "$@" ne '';
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": ".($blocked==0?"Un":"")."blocked $name";
	} else {
		my $number=Signalbot_translateContact($hash,$name);
		return "Unknown Contact" unless defined $number;
		eval {my $ret=$object->setContactBlocked($number,$blocked);};
		return "Error blocking contact:".$@ if $@ && "$@" ne '';
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": ".($blocked==0?"Un":"")."blocked $name ($number)";
	}
	return undef;
}

sub Signalbot_setContactName($@) {
    my ( $hash,$number,$name) = @_;

	if (!defined $number || !defined $name || $number eq "" || $name eq "") {
		return "setContactName: Number and Name required";
	}
	if ($number =~ /^[^\+].*/) {
		return "setContactName: Invalid number";
	}

	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;
	eval {
		$object->setContactName($number,$name);
	}; return "Error setting contact name:".$@ if $@ && "$@" ne '';

	#Add to internal inventory as well
	$hash->{helper}{contacts}{$number}=$name;
	return undef;
}

sub Signalbot_translateContact($@) {
    my ($hash,$contact) = @_;
	#if contact looks like a number +..... just return it so this can even be called transparently for numbers and contact names
	return $contact if ( $contact =~ /^\+/ );
	my $con=$hash->{helper}{contacts};

	foreach my $key (keys %{$con}) {
		my $val=$con->{$key};
		return $key if $val eq $contact;		
    }
	return undef;
}

sub Signalbot_translateGroup($@) {
    my ($hash, $groupID) = @_;
	my $groups=$hash->{helper}{groups};
	
	#Don't try to translate empty groupname
	if ($groupID eq "") { return ""; }
	
	foreach my $key (keys %{$groups}) {
		my $val=$groups->{$key};
		return $key if $val eq $groupID;		
    }
	#Group not found, so check if we simply don't know it yet
	my $ret;
	$ret=Signalbot_Refreshgroups($hash) if ($init_done);
	return $ret if $ret;
	#And try again
	$groups=$hash->{helper}{groups};
	foreach my $key (keys %{$groups}) {
		my $val=$groups->{$key};
		return $key if $val eq $groupID;		
    }
	return "Unknown group";
}

sub Signalbot_getNumber($@) {
    my ( $hash,$rec) = @_;
	my @recipient= split(/,/,$rec);
	
	#Das klappt nicht - kann man die Contacts nicht abfragen????
	#Interne liste in den readings pflegen, die bei setContactName geupdated wird und gespeichert bleibt?
	
	foreach(@recipient) {
		my $number=$hash->{helper}{contacts}{$_};
		if (!defined($number)){
		    my $bus = Net::DBus->system;
			my $service = $bus->get_service("org.asamk.Signal");
			my $object = $service->get_object("/org/asamk/Signal");

			my $number = 1;
		}
	}
}

sub Signalbot_Refreshgroups($@) {
    my ( $hash ) = @_;
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;

	my $grouplist="";
	my $ret;
	eval { $ret = $object->getGroupIds();};
	return "Error sending getting GroupIds:".$@ if $@ && "$@" ne '';
	my @groups = @$ret;
	foreach (@groups) {
		my @group=@$_;
		my $groupname;
		eval { $groupname = $object->getGroupName(\@group); };
		return "Error sending getting GroupName:".$@ if $@ && "$@" ne '';
		$hash->{helper}{groups}{$groupname}=join(" ",@group);	
		Log3 $hash->{NAME}, 5, "found group ".$groupname; 
		$grouplist=$grouplist." ".$groupname;
	}
	readingsSingleUpdate($hash, 'joinedGroups', $grouplist,0);
	return undef;
}

sub Signalbot_sendMessage($@) {
    my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": sendMessage called for $rec:$att:$mes"; 

	my @recorg= split(/,/,$rec);
	my @attach=split(/,/,$att);
	my @recipient=();
	foreach (@recorg) {
		my $trans=Signalbot_translateContact($hash,$_);
		return "Unknown recipient ".$_ unless defined $trans;
		push @recipient, $trans;
	}
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;

    eval { $object->sendMessage($mes,\@attach,\@recipient); };
	return "Error sending message:".$@ if $@;
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", encode_utf8($mes));
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);
}

#get the identifies (list of hex codes) for a group based on the name
#Check error with int(@)=1
sub Signalbot_getGroup($@) {
	my ($hash,$rec) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": getGroup $rec";
	if ( $rec =~ /^#(.*)/) {
		$rec=$1;
	}
	my $group=$hash->{helper}{groups}{$rec};
	if (!defined($group)) {
		#Check if we need to cache a new group
		my $ret;
		$ret=Signalbot_Refreshgroups($hash);
		return $ret if $ret;
		$group=$hash->{helper}{groups}{$rec};
		return "Unknown group ".$rec." please check or refresh group list" unless defined $group;
	}
	return split(" ",$group);
}

sub Signalbot_sendGroupMessage($@) {
    my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": sendGroupMessage called for $rec:$att:$mes"; 

	$rec=~s/#//g;
	my @recipient= split(/,/,$rec);
	if (@recipient>1) { return "Can only send to one group at once";}
	my @attach=split(/,/,$att);
	my @arr=Signalbot_getGroup($hash,$rec);
	return join(" ",@arr) unless int(@arr)>1;

	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;	

	eval { $object->sendGroupMessage($mes,\@attach,\@arr); };
	return "Error sending message:".$@ if $@;
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", $mes);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);
}

sub Signalbot_Execute($@) {
	my ($hash) = @_;
	#Additional check for pending message with polling if defined
	my $reactor=$hash->{helper}{reactor};
	my $ret=$reactor->step() if defined $reactor;
	my $pollInterval = AttrVal($hash->{NAME}, 'poll_interval', 0)*60;
	InternalTimer(gettimeofday() + 1, 'Signalbot_Execute', $hash, 0) if ($pollInterval > 0);
}

################################### 
sub Signalbot_Attr(@) {					#
 my ($command, $name, $attr, $val) = @_;
 my $hash = $defs{$name};
 my $msg = undef;

  if ($attr eq 'poll_interval') {
    if ( defined($val) ) {
      if ( looks_like_number($val) && $val >= 0) {
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday()+1, 'Signalbot_Execute', $hash, 0) if $val>0;
      } else {
        $msg = "$hash->{NAME}: Wrong poll intervall defined. poll_interval must be a number >= 0";
      }    
    } else {
      RemoveInternalTimer($hash);
    }
  }	elsif($attr eq "allowedPeer") {
	#Take over as is
	return undef;
  }	elsif($attr eq "babbleExclude") {
	#Take over as is
	return undef;
  } elsif($attr eq "babblePeer") {
	#Take over as is
	my $bDevice=AttrVal($hash->{NAME},"babbleDev",undef);
	if (!defined $bDevice && $init_done) {
		foreach my $dev ( sort keys %main::defs ) {
			if ($defs{$dev}->{TYPE} eq "Babble") {
				CommandAttr(undef,"$name babbleDev $dev");
				last;
			}
		}
	}
	return undef;
  } elsif($attr eq "babbleDev") {
	return undef unless (defined $val && $val ne "" && $init_done);
	my $bhash = $defs{$val};
	return "Not a Babble device $val" unless $bhash->{TYPE} eq "Babble";
	return undef;
  }
  #check for correct values while setting so we need no error handling later
  foreach ('xx', 'yy') {
	if ($attr eq $_) {
		if ( defined($val) ) {
			if ( !looks_like_number($val) || $val <= 0) {
				$msg = "$hash->{NAME}: ".$attr." must be a number > 0";
			}
		}
	}
  }
  return $msg;	
}

sub Signalbot_Notify($$) {
  my ($own_hash, $dev_hash) = @_;
  my $ownName = $own_hash->{NAME}; # own name / hash

  return "" if(IsDisabled($ownName)); # Return without any further action if the module is disabled

  my $devName = $dev_hash->{NAME}; # Device that created the events
  my $events = deviceEvents($dev_hash,1);
  
  if ($devName eq "global" and grep(m/^INITIALIZED|REREADCFG$/, @{$events})) {
	  Signalbot_Init($own_hash,"");
  }
}

################################### 
sub Signalbot_Define($$) {			#
	my ($hash, $def) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}." Define: $def";
	return "Error while loading $NETDBus. Please install $NETDBus" if $NETDBus;
	return "Error while loading $NETDBusReactor. Please install $NETDBusReactor" if $NETDBusReactor;

	$Net::DBus::VERSION =~ /^([0-9]+)\.([0-9]+)\.([0-9]+)$/;
	if(($1*100+$2*10+$3) < 120){
		return "Please install Net::DBus in version 1.2.0 or higher. Your version is: $Net::DBus::VERSION"
	}
	
	$hash->{NOTIFYDEV} = "global";
		if ($init_done) {
			Log3 $hash->{NAME}, 5, "Define init_done: $def";
			my $ret=Signalbot_Init( $hash, $def );
			return $ret if $ret;
	}
	return undef;
}
################################### 
sub Signalbot_Init($$) {				#
	my ( $hash, $args ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Init: $args";
	my @a = ();
	@a = split("[ \t]+", $args) if defined $args;
	shift @a;shift @a;
	my $name = $hash->{NAME};
	if (defined $args && int(@a) > 0)	{
		return "Define: Wrong syntax. Usage:\n" .
		       "define <name> Signalbot";
	}

	Signalbot_Set($hash, $name, "setfromreading");
	my $ret = Signalbot_setup($hash);
	$hash->{STATE} = $ret if defined $ret;
	return $ret if defined $ret;
	RemoveInternalTimer($hash);
	my $pollInterval = AttrVal($hash->{NAME}, 'poll_interval', 0)*60;
	InternalTimer(gettimeofday() + 1, 'Signalbot_Execute', $hash, 0) if ($pollInterval > 0);
	return;
}

################################### 
sub Signalbot_Catch($) {
	my $exception = shift;
	if ($exception) {
		$exception =~ /^(.*)( at.*FHEM.*)$/;
		return $1;
	}
	return undef;
}
################################### 
sub Signalbot_State($$$$) {			#reload readings at FHEM start
	my ($hash, $tim, $sname, $sval) = @_;

	return undef;
}
################################### 
sub Signalbot_Undef($$) {				#
	my ($hash, $name) = @_;
	Signalbot_disconnect($hash);
	$hash->{STATE}="Disconnected";
	RemoveInternalTimer($hash) if ( defined (AttrVal($hash->{NAME}, "poll_interval", undef)) ); 
	return undef;
}

#Any part of the message can contain FHEM or {perl} commands that get executed here
#This is marked by being in (brackets) - returned is the result (without brackets)
#If its a media stream, a file is being created and the temporary filename (delete later!) is returned
#Question: more complex commands could contain spaces but that will require more complex parsing

sub SignalBot_replaceCommands(@) {
	my ($hash, @data) = @_;
	
	my @processed=();
	
	foreach my $string (@data) {
		#Commands need to be enclosed in brackets
		if ($string =~ /^\((.*)\)$/) {
			$string=$1; #without brackets
			my %dummy; 
			my ($err, @newargs) = ReplaceSetMagic(\%dummy, 0, ( $string ) );
			my $msg="";
			if ( $err ) {
				Log3 $hash->{NAME}, 1, $hash->{NAME}.": parse cmd failed on ReplaceSetmagic with :$err: on  :$string:";
			} else {
				$msg = join(" ", @newargs);
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": parse cmd returned :$msg:";
			}
			$msg = AnalyzeCommandChain( $hash, $msg );
			#If a normal FHEM command (no return value) is executed, $msg is undef - just the to empty string then
			if (!defined $msg) { 
				$msg=""; 
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": commands executed without return value";
			}
			#Only way to distinguish a real error with the return stream
			if ($msg =~ /^Unknown command/) { 
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": Error message: ".$msg;
				return ($msg, @processed); 
			}
			
			my ( $isMediaStream, $type ) = SignalBot_IdentifyStream( $hash, $msg ) if ( defined( $msg ) );
			if ($isMediaStream<0) {
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": Media stream found $isMediaStream $type";
				my $tmpfilename="/tmp/signalbot".gettimeofday().".".$type;
				my $fh;
				#tempfile() would be the better way, but is not readable by signal-cli (how to set world-readable?)
				#could be changed with "chmod 0666, $tmpfilename;" which should even work on Windows, but what's the point - dbus/signal-cli works on Linux only anyways
				#my ($fh, $tmpfilename) = tempfile();
				if(!open($fh, ">", $tmpfilename,)) {
				#if (!defined $fh) {
					Log3 $hash->{NAME}, 1, $hash->{NAME}.": Can't write $tmpfilename";
					#return undef since this is a fatal error 
					return ("Can't write $tmpfilename",@processed);
				}
				print $fh $msg;
				close($fh);
				#If we created a file return the filename instead
				push @processed, $tmpfilename;
			} else {
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": normal text found:$msg";
				#No mediastream - return what it was
				push @processed, $msg;
			}
		} else {
			#Not even in brackets, return as is
			push @processed, $string;
		}
		
	}
	
	return (undef,@processed);
}


######################################
#  Get a string and identify possible media streams
#  Copied from Telegrambot
#  PNG is tested
#  returns 
#   -1 for image
#   -2 for Audio
#   -3 for other media
# and extension without dot as 2nd list element

sub SignalBot_IdentifyStream($$) {
  my ($hash, $msg) = @_;

  # signatures for media files are documented here --> https://en.wikipedia.org/wiki/List_of_file_signatures
  # seems sometimes more correct: https://wangrui.wordpress.com/2007/06/19/file-signatures-table/
  return (-1,"png") if ( $msg =~ /^\x89PNG\r\n\x1a\n/ );    # PNG
  return (-1,"jpg") if ( $msg =~ /^\xFF\xD8\xFF/ );    # JPG not necessarily complete, but should be fine here
  
  return (-2 ,"mp3") if ( $msg =~ /^\xFF\xF3/ );    # MP3    MPEG-1 Layer 3 file without an ID3 tag or with an ID3v1 tag
  return (-2 ,"mp3") if ( $msg =~ /^\xFF\xFB/ );    # MP3    MPEG-1 Layer 3 file without an ID3 tag or with an ID3v1 tag
  
  # MP3    MPEG-1 Layer 3 file with an ID3v2 tag 
  #   starts with ID3 then version (most popular 03, new 04 seldom used, old 01 and 02) ==> Only 2,3 and 4 are tested currently
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x03/ );    
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x04/ );    
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x02/ );    

  return (-3,"pdf") if ( $msg =~ /^%PDF/ );    # PDF document
  return (-3,"docx") if ( $msg =~ /^PK\x03\x04/ );    # Office new
  return (-3,"docx") if ( $msg =~ /^PK\x05\x06/ );    # Office new
  return (-3,"docx") if ( $msg =~ /^PK\x07\x08/ );    # Office new
  return (-3,"doc") if ( $msg =~ /^\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1/ );    # Office old - D0 CF 11 E0 A1 B1 1A E1

  return (-4,"mp4") if ( $msg =~ /^....\x66\x74\x79\x70\x69\x73\x6F\x6D/ );    # MP4 according to Wikipedia
  return (-4,"mpg") if ( $msg =~ /^\x00\x00\x01[\xB3\xBA]/ );    # MPG according to Wikipedia
  
  return (0,"txt");
}

1;

#Todo Write update documentation

=pod
=item device
=item summary provides an interface to the Signal Messenger, via signal_cli running as dbus daemon 
=item summary_DE stellt eine Schnittstelle zum Signal Messenger ueber das signal_cli Paket in dbus daemon modus zur Verfuegung

=begin html

<a name="Signalbot"></a>
<h3>Signalbot</h3>
For German documentation see <a href="https://wiki.fhem.de/wiki/Signalbot">Wiki</a>
<ul>
	<a name="Signalbot"></a>
		provides an interface to the Signal Messenger, via signal_cli running as dbus daemon<br>
		The signal_cli package needs to be installed. See github for installation details on <a href="https://github.com/AsamK/signal-cli">signal-cli</a><br>
		An install script is available in the <a href="https://forum.fhem.de/index.php/topic,118370.0.html">FHEM forum</a><br>
		<br><br>
		Supported functionality (mainly due to limitations of the signal-cli dbus interface:<br>
		<ul>
		<li>Send messages to individuals and/or groups with or without attachments</li>
		<li>Retrieve the list of joined groups in order to allow using group names when sending (automatically done when encountering an unknown group)</li>
		<b>Limitations:</b><br>
		<li>The whole setup, registration and eving joining groups has to be done from signal-cli since a lot of functionality is not supported (yet) via the Dbus interface. The install shell script is however guiding through this process.</li>
		<br>
		</ul>
	<a name="SignalbotDefine"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; Signalbot</code><br>
		No arguments (for now)<br>
		<br>
	</ul>

	<a name="SignalbotSet"></a>
	<b>Set</b>
	<ul>
		<li><b>set &lt;name&gt; &lt;send&gt; [@&lt;Recipient1&gt; ... @&lt;RecipientN&gt;] [#&lt;GroupId1&gt; ... #&lt;GroupIdN&gt;] [&&lt;Attachment1&gt; ... &&lt;AttachmentN&gt;] [&lt;Text&gt;]</b><br>
			<a name="send"></a>
			Send a message to a Signal recipient using @Name or @+49xxx as well as groups with #Group or #@Group along with an attachment with &<path to file> and a message.
		</li>
		<br>
		<li>
			<a name="send2"></a>
			<li>Use round brackets to let FHEM execute the content (e.g <code>&({plotAsPng('SVG_Temperatures')}</code></li>
			<li>If a recipient, group or attachment contains white spaces, the whole expression (including @ # or &) needs to be put in double quotes. Escape quotes within with \"</li>
			<li>If the round brackets contain curly brackets to execute Perl commands, two semi-colons (;;) need to be used to seperate multiple commands and at the end. The return value will be used e.g. as recipient</li>
			<li>For compatibility reasons @# can also be used to mark group names</li>
			<li>Messages to multiple recipients will be sent as one message</li>
			<li>Messages to multiple groups or mixed with individual recipients will be sent in multiple messages</li>
			<li>Attachments need to be file names readable for the fhem user with absolute path or relative to fhem user home</li>
			<li>Recipients can be either contact names or phone numbers (starting with +). Since signal-cli only understand phone numbers, 
			Signalbot tries to translate known contact names from its cache and might fail to send the message if unable to decode the contact<br>
			<li>To send multi line messages, use "\\n" in the message text</li>
			<br>
			Example:<br>
			<code>set Signalbot send "@({my $var=\"Joerg\";; return $var;;})" #FHEM "&( {plotAsPng('SVG_Temperatures')} )" Here come the current temperature plot</code><br>
			</ul>
			<br>
		</li>
		<a name="refreshGroups"></a>
		<li><b>set refreshGroups</b><br>
		Read the currently joined groups from Signal. Typically not necessary since groups get discovered on the fly. The list is saved in the reading "joinedGroups"<br>
		</li>
		<li><b>set saveContacts</b><br>
		<a name="saveContacts"></a>
		Save the internal list of discovered contact name to phone number conversions into the reading "contactList"<br>
		</li>
		<li><b>set setContact &ltnumber&gt &ltname&gt</b><br>
		<a name="setContact"></a>
		Define a nickname for a phone number to be used with the send command and in readings<br>
		</li>
		<li><b>set createGroup &ltgroupname&gt [&&ltgroup picture&gt]</b><br>
		<a name="createGroup"></a>
		Define a new Signal group with the specified name.<br>
		Note: Pictures >2MB are known to cause issues and are blocked.<br>
		</li>
		<li><b>set updateGroup &ltgroupname&gt #[&ltnew groupname&gt] [&&ltgroup picture&gt]</b><br>
		<a name="updateGroup"></a>
		Update the name and/or group picture for an existing group.<br>
		Note: Pictures >2MB are known to cause issues and are blocked.<br>
		</li>
		<li><b>set invite &ltgroupname&gt &ltcontact&gt</b><br>
		<a name="invite"></a>
		Invite new members to an existing group.<br>
		</li>		
		<li><b>set block #&ltgroupname&gt|&ltcontact&gt</b><br>
		<a name="block"></a>
		Put a group or contact on the blocked list (at the server) so you won't receive messages anymore. While the attribute "allowedPeer" is handled on FHEM level and messages are still received (but ignored), FHEM will not receive messages anymore for blocked communication partners<br>
		</li>
		<li><b>set unblock #&ltgroupname&gt|&ltcontact&gt</b><br>
		<a name="unblock"></a>
		Reverses the effect of "block", re-enabling the communication.<br>
		</li>		
		<li><b>set reinit</b><br>
		<a name="reinit"></a>
		Re-Initialize the module. For testing purposes when module stops receiving or has other issues. Should not be necessary.<br>
		</li>
		<br>
	</ul>

	<a name="SignalbotAttr"></a>
	<b>Attributes</b>
	<ul>
		<br>
		<li><b>poll_interval</b><br>
		<a name="poll_interval"></a>
			Set the polling interval in minutes to query new messages<br>
			Typically not required, since the module gets notified when new messages arrive.<br>
			Default: -, valid values: decimal number<br>
		</li>
		<li><b>allowedPeer</b><br>
		<a name="allowedPeer"></a>
			Comma separated list of recipient(s) and/or groupId(s), allowed to
			update the msg.* readings and trigger new events when receiving a new message.<br>
			<b>If the attribute is not defined, everyone is able to trigger new events!!</b>
		</li>
		<li><b>babblePeer</b><br>
		<a name="babblePeer"></a>
			Comma separated list of recipient(s) and/or groupId(s) that will trigger that messages are forwarded to a Babble module defined by "BabbleDev". This can be used to interpret real language interpretation of messages as a chatbot or to trigger FHEM events.<br>
			<b>If the attribute is not defined, nothing is sent to Babble</b>
		</li>
		<li><b>babbleDev</b><br>
		<a name="babbleDev"></a>
			Name of Babble Device to be used. This will typically be automatically filled when bubblePeer is set.<br>
			<b>If the attribute is not defined, nothing is sent to Babble</b>
		</li>
		<br>
	</ul>
	<br>
	<a name="SignalbotReadings"></a>
	<b>Readings</b>
	<ul>
		<br>
		<li><b>(prev)msgAttachment</b></li>
		Attachment(s) of the last received (or for history reasons the previous before). The path points to the storage in signal-cli and can be used to retrieve the attachment.<br>
		<li><b>(prev)msgGroupName</b></li>
		Group of the last message (or for history reasons the previous before). Empty if last message was a private message<br>
		<li>(prev)msgSender</b></li>
		Sender that sent the last message (or previous before) <br>
		<li><b>(prev)msgText</b></li>
		Content of the last message <br>
		<li><b>(prev)msgTimestamp</b></li>
		Time the last message was sent (a bit redundant, since all readings have a timestamp anyway<br>
		<li><b>sentMsg</b></li>
		Content of the last message that was sent from this module<br>
		<li><b>sentRecipient</b></li>
		Recipient of the last message that was sent<br>
		This is taken from the actual reply and will contain the last recipient that confirmed getting the message in case multiple recipients or group members got it<br>
		<li><b>sentMsgTimestamp</b></li>
		Timestamp the message was received by the recipient. Will show pending of not confirmed (likely only if even the Signal server did not get it)<br>
		<li><b>contactList</b></li>
		List of known contacts in the format Number1=Name1,Number2=Name2,...<br>
		Auto generated from know contacts with "saveContacts"<br>
		<li><b>joinedGroups</b></li>
		Space separated list of groups the registered number is joined to<br>
	<br>
</ul>

=end html

=cut
