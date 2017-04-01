#!/usr/bin/perl
use strict; 
use warnings;

use IO::Socket;
use IO::Handle;
use IO::Select;
use HTTP::Headers;
use HTTP::Request;
use LWP::UserAgent;
use Time::HiRes qw(gettimeofday);

# Hyperion config
our $hyperion_host = "localhost";
our $hyperion_port = 19444;
our @hyperion_effect_startup = ("Rainbow swirl", 7500, '{"rotation-time": 8, "brightness": 1, "reverse": false}');
our @hyperion_effect_poweron = ("Cinema brighten lights", 15000, '{"fade-time": 8, "color-start": [0, 0, 0], "color-end": [20, 115, 200]}');
our @hyperion_effect_poweroff = ("Cinema dim lights", 5000, '{"fade-time": 3, "color-start": [20, 115, 200], "color-end": [0, 0, 0]}');

# Lirc config
our $lirc_host = "localhost";
our $lirc_port = 8765;

# Homebridge config - accessory / characteristic IDs from http://HOST:PORT/accessories
our $homebridge_host = "localhost";
our $homebridge_port = 51826;
our $homebridge_pin = "123-45-678";
our $homebridge_priority = 100;
our $homebridge_accessory_id = 2;
our $homebridge_backlight_power_id = 9;
our $homebridge_ambilight_power_id = 15;

STDOUT->autoflush(1);

our $last_time = 0;
our $lirc_socket = undef;
our $hyperion_socket = undef;
our $homebridge_alive = undef;
our $lirc_sockets = IO::Select->new();

# Kill any previous instances of the script
kill_previous_instance();

# Turn off Ambilight at startup
check_sockets();
control_ambilight("STARTUP");

# Main
$SIG{PIPE} = sub {
	check_sockets();
};

while (1) {
	my $this_time = time();
	
	if ($this_time - $last_time > 10) {
		$last_time = $this_time;		
		check_sockets();
	}
	
	my @read_ready = $lirc_sockets->can_read(60);
	
	foreach my $read_handle(@read_ready) {
		my $text = <$read_handle>; {
			if ($text =~ m/^([\da-f]+)\s(\d\d)\s(\S+)\s(\S+)$/) {
				my($code, $repeat, $button, $control) = ($1, $2, $3, $4);
				handle_lirc_command($read_handle, $code, $repeat, $button, $control);
			}
		}
	}
}

sub check_sockets {
	while (1) {
		if ((defined $lirc_socket) && (!$lirc_socket->connected() || !(print $lirc_socket "VERSION\n"))) {
			print "Lirc socket has disconnected or errored! - $! $@\n";
			close_lirc_socket();
		}
		
		if ((defined $hyperion_socket) && (!$hyperion_socket->connected())) {
			print "Hyperion socket has disconnected or errored! - $! $@\n";
			close_hyperion_socket();
		}
		
		# Only check Homebridge at startup to ensure it's started before this script
		if (!$homebridge_alive) {
			my $homebridge_socket = new IO::Socket::INET(
				PeerAddr => $homebridge_host,
				PeerPort => $homebridge_port,
				Proto => 'tcp',
				Timeout => 2
			);
			
			if ($homebridge_socket) {
				close($homebridge_socket);
				undef $homebridge_socket;
				$homebridge_alive = 1;
			} else {
				$homebridge_alive = 0;
			}
		}
		
		if (!$homebridge_alive) {
			sleep(1);
		} elsif (!open_lirc_socket() || !open_hyperion_socket()) {
			sleep(10);
		} else {
			last;
		}
	}
}

sub open_lirc_socket {
	if (!(defined $lirc_socket)) {
		print "Lirc socket is being opened...";
		
		our $lirc_socket = new IO::Socket::INET(
			PeerAddr => $lirc_host,
			PeerPort => $lirc_port,
			Proto => 'tcp',
		);
		
		if ($lirc_socket) {
			print "done!\n";
			$lirc_sockets->add($lirc_socket);
			return 1;
		} else {
			print "failed! - $! $@\n";
			return 0;
		}
	}
	
	return 1;
}

sub close_lirc_socket {
	if ((defined $lirc_socket)) {
		print "Lirc socket is being closed...";
		
		$lirc_sockets->remove($lirc_socket);
		close($lirc_socket);
		undef $lirc_socket;
		
		print "done!\n";
	}
	
	return 1;
}

sub open_hyperion_socket {
	if (!(defined $hyperion_socket)) {
		print "Hyperion socket is being opened...";
		
		our $hyperion_socket = new IO::Socket::INET(
			PeerAddr => $hyperion_host,
			PeerPort => $hyperion_port,
			Proto => 'tcp',
		);
		
		if ($hyperion_socket) {
			print "done!\n";
			return 1;
		} else {
			print "failed! - $! $@\n";
			return 0;
		}
	}
	
	return 1;
}

sub close_hyperion_socket {
	if ((defined $hyperion_socket)) {
		print "Hyperion socket is being closed...";
		
		close($hyperion_socket);
		undef $hyperion_socket;
		
		print "done!\n";
	}
	
	return 1;
}

sub handle_lirc_command {
	my($read_handle, $code, $repeat, $button, $control) = @_;
	
	print "Lirc socket recieved IR command from " . $read_handle->peerhost() . ":" . $read_handle->peerport();
	print("\t$control\t$button\t$repeat\n");

	if (($control eq "Samsung") && ($repeat == 0)) {
		if ($button eq "KEY_POWERON") {
			control_ambilight("POWERON");
		} elsif ($button eq "KEY_POWEROFF") {
			control_ambilight("POWEROFF");
		}
	}
}

sub control_ambilight {
	my($control) = @_;
	print "Controlling Ambilight with command '$control'\n";
	
	my $backlight_on = control_homebridge($homebridge_accessory_id, $homebridge_backlight_power_id);
	
	if ($backlight_on) {
		return;
	}
	
	if ($control eq "STARTUP") {
		control_homebridge($homebridge_accessory_id, $homebridge_ambilight_power_id, 0);
		control_homebridge($homebridge_accessory_id, $homebridge_backlight_power_id, 0);
		
		if (@hyperion_effect_startup && ((scalar @hyperion_effect_startup) == 3)) {
			control_hyperion_effect($hyperion_effect_startup[0], $hyperion_effect_startup[1], $hyperion_effect_startup[2]);
		}
		
	} elsif ($control eq "POWERON") {
		control_homebridge($homebridge_accessory_id, $homebridge_ambilight_power_id, 1);
		
		if (@hyperion_effect_poweron && ((scalar @hyperion_effect_poweron) == 3)) {
			control_hyperion_effect($hyperion_effect_poweron[0], $hyperion_effect_poweron[1], $hyperion_effect_poweron[2]);
		}
		
	} elsif ($control eq "POWEROFF") {
		control_homebridge($homebridge_accessory_id, $homebridge_ambilight_power_id, 0);
		
		if (@hyperion_effect_poweroff && ((scalar @hyperion_effect_poweroff) == 3)) {
			control_hyperion_effect($hyperion_effect_poweroff[0], $hyperion_effect_poweroff[1], $hyperion_effect_poweroff[2]);
		}
	}
}

sub control_homebridge {
	my($accessory_id, $characteristic_id, $value) = @_;
	
	if (defined $value) {
		my $homebridge = do_homebridge_request("PUT", "/characteristics", '{"characteristics": [{"aid": ' . $accessory_id . ', "iid": ' . $characteristic_id . ', "value": ' . $value . '}]}');
		
		if ($homebridge->is_success) {
			return ($value == 1);
		}
	} else {
		my $homebridge = do_homebridge_request("GET", "/characteristics?id=" . $accessory_id . "." . $characteristic_id);
		
		if (!$homebridge->is_success || (rindex($homebridge->content, "value") == -1)) {
			return -1;
		} else {
			return ((rindex($homebridge->content, '"value":1') >= 0) || (rindex($homebridge->content, '"value":true') >= 0));
		}
	}
}

sub control_hyperion_effect {
	my($effectName, $duration, $effectArguments) = @_;
	my $priority = $homebridge_priority - 10;
	
	print "\tStarting Hyperion effect '$effectName'...";
	
	my $request = '{"command": "clear", "priority": ' . $priority . '}';
	my $response = do_hyperion_request($request, 1024);
	
	$request = '{"command": "effect", "priority": ' . $priority . ', "duration": ' . $duration . ', "effect": {"name": "' . $effectName . '", "args": ' . $effectArguments . '}}';	
	$response = do_hyperion_request($request, 1024);
	
	if ($response eq '{"success":true}') {
		print "done!\n";
	} else {
		print "failed! - $response\n";
	}
}

sub do_hyperion_request {
	my($request, $buffer_size) = @_;
	
	my $response = "";
	$hyperion_socket->send($request . "\n");
	$hyperion_socket->recv($response, $buffer_size);
	chomp $response;
	
	return $response;
}

sub do_homebridge_request {
	my($method, $uri, $data) = @_;
	
	print "\tRequesting Homebridge URI '$uri'...";
	
	my $headers = new HTTP::Headers(
		Accept => "application/json",
		Content_Type => "application/json",
		Authorization => $homebridge_pin
	);

	my $request = new HTTP::Request($method, "http://" . $homebridge_host . ":" . $homebridge_port . $uri, $headers, $data);

	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($request);
	
	if ($response->is_success) {
		print "done!\n";
	} else {
		print "failed! - " . $response->status_line . "\n";	
	}
	
	return $response;
}

sub kill_previous_instance {
	my $victim = "/usr/bin/perl /usr/local/bin/ambilight-lirc.pl";

	open(FILE, "ps -ef|");
	my @psout = <FILE> ;
	close FILE;
	
	foreach(@psout) {
		chomp;
		my ($uid, $pid, $ppid, $c, $stime, $tty, $time, $cmd) = split(/\s+/, $_, 8);

		if ($cmd eq $victim) {
			if ($pid != $$) {
				print "Killing previous instance PID '$pid' \n";
				`kill $pid`;
			}
		}
	}
}