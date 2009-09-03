package Business::OnlinePayment::WorldPay;

use 5.008008;
use strict;
use warnings;
use Carp;

use Template;                                   # construct XML requests
use XML::TreeBuilder;                           # parse XML responses

use Net::SSLeay qw(post_https make_headers);    # submit requests
use MIME::Base64;                               # basic authentication

use base qw(Exporter Business::OnlinePayment);  # Exporter just for $VERSION checking


our $VERSION  = '0.09';
our $DEBUG_FH = \*STDERR;                       # debugging output destination 


my ($Payment_Methods, $XML_Error_Codes) = _get_maps();


my $servers = {
    live => {
        server    => 'secure.ims.worldpay.com',
        path      => '/jsp/merchant/xml/paymentService.jsp',
        port      => 443,
    },
    test => {
        server    => 'secure-test.wp3.rbsworldpay.com',
        path      => '/jsp/merchant/xml/paymentService.jsp',
        port      => 443,
    },
};


sub debug
{
    my ($self, $value, $filename) = @_;

    $self->{debug} = $value if defined $value;

    if ( $filename ) {
        if (open(my $fh, ">>", $filename)) {
            my $old_fh = select($fh);
            $| = 1;                    # output autoflush
            select($old_fh);
            $DEBUG_FH = $fh;
        }
        else {
            carp "cannot open debugging file $filename: $!\n";
        }
    }

    return $self->{debug};
}


sub set_server
{
    my ($self, $server_type) = @_;

    $self->{'_server'} = $server_type;   # 'live' or 'test'

    $self->server( $servers->{$server_type}->{'server'} );
    $self->path(   $servers->{$server_type}->{'path'}   );
    $self->port(   $servers->{$server_type}->{'port'}   );
}


sub set_defaults    # called by B::OP constructor
{
    my $self = shift;

    $self->{'_content'} = {};

    _launder_envariables();                 # clean up WORLDPAY_* variables

    # B::OP creates the following accessors:
    #     server, port, path, test_transaction, transaction_type,
    #     server_response, is_success, authorization,
    #     result_code, error_message,

    # let's create some more:

    $self->build_subs(
        qw/
            installation login password version currency
            action result_code status_code status_detail
            cvv2_response avs_code risk_score 
        /
    );

    $self->test_transaction(0);             # default to live server

    $self->version('1.4');                  # paymentService "version" attribute

    $self->action('payment');               # default action is payment

    $self->currency('EUR');                 # default value for currencyCode

    if ($ENV{WORLDPAY_DEBUG}) {
        if ($ENV{WORLDPAY_DEBUG} =~ /^\d+$/) {
            $self->debug( 1 );
        }
        else {
            $self->debug( 1, $ENV{WORLDPAY_DEBUG} );
        }
    }
}


sub submit
{
    my $self = shift;

    my %content = $self->content;

    if ($content{action}) {
        $content{action} = 'payment'
            if $content{action} =~ /^ \s* normal \s+ authori[zs]ation \s* $/ix;
        $self->action( lc $content{action} );
    }

    ################ initialize object ################

    # standard B::OP attributes
    $self->$_( '' ) for qw/is_success
                           authorization
                           result_code
                           error_message
                           server
                           port
                           path
                           server_response/;

    $self->transaction_type( '' ) unless $self->transaction_type;

    # additional B::OP::WorldPay attributes
    $self->$_( '' ) for qw/status_code
                           status_detail
                           cvv2_response
                           avs_code
                           risk_score/;

    $self->set_server( $self->test_transaction ? 'test' : 'live' );

    $self->installation( $content{installation} || $ENV{WORLDPAY_INSTALLATION_ID} );
    $self->login(        $content{login}        || $ENV{WORLDPAY_MERCHANT_CODE}   );
    $self->password(     $content{password}     || $ENV{WORLDPAY_XML_PASSWORD}    );

    if ($self->debug) {
        print $DEBUG_FH "\n";
        print $DEBUG_FH '*' x 80, "\n\n";
        print $DEBUG_FH "installation: ", $self->installation, "\n";
        print $DEBUG_FH "login: ",        $self->login,        "\n";
        print $DEBUG_FH "password: ",     $self->password,     "\n";
    }

    ##### get template & variables for xml request ####

    my ($xml_template, $template_vars);

    my $action = $self->action;

    if ($action eq 'status' || $action eq 'cancel' || $action eq 'cancel_or_refund') {
        ($xml_template, $template_vars) = $self->status_inquiry_or_cancel;
    }
    elsif ( $action eq 'refund' ) {
        ($xml_template, $template_vars) = $self->refund;
    }
    else {
        ($xml_template, $template_vars) = $self->payment;
    }

    ############### create XML request ################

    my $post_data_xml;

    my $tt = Template->new();

    $tt->process( \$xml_template, $template_vars, \$post_data_xml ) ||
        croak $tt->error();

    if ($self->debug) {
        print $DEBUG_FH "\n", "=" x 80, "\n";
        print $DEBUG_FH " " x 35, "REQUEST:\n";
        print $DEBUG_FH "=" x 80, "\n\n";
        print $DEBUG_FH "post_data_xml = \n$post_data_xml\n";
        print $DEBUG_FH "POST_HTTPS: ", $self->server . $self->path, "\n";
    }

    ################# submit request ##################

    my ($page, $response, %headers) = post_https(
        $self->server,
        $self->port,
        $self->path,
        make_headers(
            Authorization => 'Basic ' . MIME::Base64::encode(
                 $self->login . ":" . $self->password,  ''
            )
        ),
        $post_data_xml,
    );

    ################ examine response #################

    if ($self->debug) {
        my $prettier_xml;
        ($prettier_xml = $page) =~ s/></>\n</g;  # split tags w/ newlines
        print $DEBUG_FH "\n", "=" x 80, "\n";
        print $DEBUG_FH " " x 35, "RESPONSE:\n";
        print $DEBUG_FH "=" x 80, "\n\n";

        print $DEBUG_FH "$response\n\n";
        print $DEBUG_FH "HEADERS:\n";
        print $DEBUG_FH "  $_: $headers{$_}\n" for sort keys %headers;
        print $DEBUG_FH "\nXML:\n$prettier_xml\n";
        print $DEBUG_FH "-" x 80, "\n\n";
    }

    $self->server_response( $response );                # standard B::OP field

    if ($self->server_response =~ /\b401 Authorization Required/) {
        $self->is_success(0);
        $self->error_message('Authorization Required');
        return;
    }

    unless ($page && $self->server_response =~ /\b200 OK/) {
        $self->is_success(0);
        $self->error_message(
            'There was a problem communicating with the payment server. ' .
            'Please try again.'
        );
        return;
    }

    ############### parse XML response ################

    my $xml = XML::TreeBuilder->new;
    $xml->parse($page);

    if ($self->debug) {
        print $DEBUG_FH "XML::TreeBuilder dump:\n";
        $xml->dump($DEBUG_FH);
        print $DEBUG_FH "\n";
    }

    # structure of the XML response varies

    my (
        $error, $last_event, $return_code, $cvc_result, $avs_result, $risk, $ok, 
    );

    # response for various errors:
    if ($error = $xml->find('error')) {
        $self->is_success(0);                           # standard B::OP field
        $self->authorization( 'REFUSED' );
        $self->status_code( $error->attr('code') );
        $self->status_detail( $XML_Error_Codes->{ $error->attr('code') });
        $self->error_message( $error->as_text );        # standard B::OP field
    }

    # response for payment requests or status inquiries:
    elsif ($last_event = $xml->find('lastEvent')) {    # response for payments

        $self->status_detail( $last_event->as_text );

        if ($last_event->as_text eq 'AUTHORISED') {     # UK spelling

            $self->is_success(1);
            $self->authorization( 'AUTHORIZED' );       # switching to US spelling
            $self->status_code( 'OK' );
            $self->status_detail( 'AUTHORIZED' );

        }
        elsif ($last_event->as_text eq 'REFUSED') {

            if ($return_code = $xml->find('ISO8583ReturnCode')) {
                $self->is_success(0);
                $self->authorization( 'REFUSED' );
                $self->result_code( $return_code->attr('code') );
                $self->status_code( 'DECLINE' );
                $self->error_message( $return_code->attr('description') );
            }

        }

# if needed, can provide special handling for other last_event values:   
#       CANCELLED, CAPTURED, SETTLED, SETTLED_BY_MERCHANT,
#       SENT_FOR_REFUND, REFUNDED_BY_MERCHANT, CHARGED_BACK
#
#       elsif ($last_event->as_text eq 'XXX') {
#       }

        else {
            $self->is_success(1);
        }

        # get CVCResultCode description if present

        if ($cvc_result = $xml->find('CVCResultCode')) {
            $self->cvv2_response( $cvc_result->attr('description') );
        }

        # get AVSResultCode description if present

        if ($avs_result = $xml->find('AVSResultCode')) {
            $self->avs_code( $avs_result->attr('description') );
        }

        # get riskScore if present

        if ($risk = $xml->find('riskScore')) {
            $self->risk_score( $risk->attr('value') );
        }

    }

    # response for cancel request:
    elsif ( $ok = $xml->find('ok') and $ok->find('cancelReceived') ) {
        $self->is_success(1);
        $self->status_detail( 'CANCEL_REQUEST_RECEIVED' );
    }

    # response for refund request:
    elsif ( $ok = $xml->find('ok') and $ok->find('refundReceived') ) {
        $self->is_success(1);
        $self->status_detail( 'REFUND_REQUEST_RECEIVED' );
    }

    # response for UNDOCUMENTED cancelOrRefund request:
    elsif ( $ok = $xml->find('ok') and $ok->find('voidReceived') ) {
        $self->is_success(1);
        $self->status_detail( 'CANCEL_OR_REFUND_REQUEST_RECEIVED' );
    }

    $xml->delete;

    if ($self->debug) {
        print $DEBUG_FH "\n", "=" x 80, "\n";
        print $DEBUG_FH " " x 35, "RESULTS:\n";
        print $DEBUG_FH "=" x 80, "\n\n";
 
        print $DEBUG_FH  "Standard B::OP attributes:\n";
 
        print $DEBUG_FH "test_transaction = ", $self->test_transaction, "\n";
        print $DEBUG_FH "transaction_type = ", $self->transaction_type, "\n";
        print $DEBUG_FH "is_success       = ", $self->is_success,       "\n";
        print $DEBUG_FH "authorization    = ", $self->authorization,    "\n";
        print $DEBUG_FH "result_code      = ", $self->result_code,      "\n";
        print $DEBUG_FH "error_message    = ", $self->error_message,    "\n";
        print $DEBUG_FH "server           = ", $self->server,           "\n";
        print $DEBUG_FH "port             = ", $self->port,             "\n";
        print $DEBUG_FH "path             = ", $self->path,             "\n";
        print $DEBUG_FH "server_response  = ", $self->server_response,  "\n\n";
 
        print $DEBUG_FH "Additional B::OP::WorldPay attributes:\n";
 
        print $DEBUG_FH "status_code      = ", $self->status_code,     "\n";
        print $DEBUG_FH "status_detail    = ", $self->status_detail,   "\n";
        print $DEBUG_FH "cvv2_response    = ", $self->cvv2_response,   "\n";
        print $DEBUG_FH "avs_code         = ", $self->avs_code,        "\n";
        print $DEBUG_FH "risk_score       = ", $self->risk_score,      "\n\n";
 
        print $DEBUG_FH "-" x 80, "\n\n";
    }
}


sub payment
{
    my $self = shift;

    my %content = $self->content;

    $self->required_fields( 'type' );

    if ($content{type} =~ /^solo/i) {
        croak("missing required field issue_number or start_date")
            unless exists $content{issue_number} || exists $content{start_date};
    }

    my @required_fields = @{ $Payment_Methods->{ lc $content{type} }{_required} };

    $self->required_fields( @required_fields );

    ########### initialize template variables #########

    $self->currency( $content{currency} ) if $content{currency};
    my $currency = $self->currency;

    my $amount_value = $content{amount};

    # amount must be specified with an "exponent"
    # Example: $123.45 would be specified as value = "12345", exponent = "2"

    my $amount_exponent = 2;                # works for all but Indonesian Rupiah

    if ($amount_value) {
        $amount_value =~ s/,(?=\d\d$)/./g;                  # 123,45    => 123.45
        $amount_value =~ s/,//g;                            # 12,345.46 => 12345.46
        $amount_value =  sprintf "%.2f", $amount_value;     # 123       => 123.00
        $amount_value =~ s/\.//g;                           # 123.00    => 12300
    }

    # strip non-digits from card number
    my $card_number = '';
    if ( $content{card_number} ) {
        ( $card_number = $content{card_number} ) =~ s/\D//g;
    }

    # separate month and year values for expiryDate

    my ($exp_month, $exp_year); 
    if ( $content{exp_date} ) {
        ($exp_month, $exp_year) = split /\//, $content{exp_date};
        $exp_month = sprintf "%02d", $exp_month;
        $exp_year  = $exp_year < 100 ? 2000 + $exp_year : $exp_year;            # Y3K problem
    }

    # Solo & Maestro cards may have startDate
    # separate month and year values for startDate

    my ($start_month, $start_year);
    if ($content{start_date}) {
        ($start_month, $start_year) = split /\//, $content{start_date};
        $start_month = sprintf "%02d", $start_month;
        $start_year  = $start_year < 100 ? 2000 + $start_year : $start_year;    # Y3K problem
    }

    # get first and last names from cardHolderName

    my ($first_name, $last_name);
    if ($content{name}) {
        my @names = split ' ', $content{name};
        $last_name  = pop @names;
        $first_name = join ' ' => @names;
    }

    # WorldPay suggests putting the whole address in the street field
    # with the exception of the postal and country codes

    my @address;
    push @address, $content{address} if $content{address};
    push @address, $content{city}    if $content{city};
    push @address, $content{state}   if $content{state};
    my $street = join ', ' => @address;

    ########### get XML template for request ##########

    my $xml_template = _get_xml_template( $self->action );

    ########### initialize data for template ##########

    my $template_vars = {

        merchantCode   => $self->login,

        version        => $self->version,

        orderCode      => $content{order_number},

        installationId => $self->installation,

        description    => $content{description},

        amount => {
            value        => $amount_value,
            currencyCode => $self->currency,
            exponent     => $amount_exponent,
        },

        paymentDetails => {
            paymentType    => $Payment_Methods->{lc $content{type}}{paymentType},
            action         => 'AUTHORISE',
            cardNumber     => $card_number,
            expiryDate     => {
                month => $exp_month,
                year  => $exp_year,
            },
            cardHolderName => $content{name},
            issueNumber    => $content{issue_number},
            startDate      => {
                month => $start_month,
                year  => $start_year,
            },
            cvc            => $content{cvc},
            cardAddress    => {
                firstName       => $content{first_name},
                lastName        => $content{last_name},
                street          => $street,
                postalCode      => $content{zip},
                countryCode     => $content{country},
                telephoneNumber => $content{phone},
            },
        },

        # required for 3D secure authentication
        session => {
            shopperIPAddress => $content{ip_address},
            id               => $content{session_id},
        },

        # required for 3D secure authentication
        shopper => {
            acceptHeader    => $content{accept_header},
            userAgentHeader => $content{user_agent},
        },

    };

    return ($xml_template, $template_vars);
}


sub status_inquiry_or_cancel
{
    my $self = shift;

    my %content = $self->content;

    $self->required_fields( qw/order_number/ );

    ########### get XML template for request ##########

    my $xml_template = _get_xml_template( $self->action );

    ########### initialize data for template ##########

    my $template_vars = {
        merchantCode => $self->login,
        version      => $self->version,
        orderCode    => $content{order_number},
    };

    return ($xml_template, $template_vars);
}


sub refund
{
    my $self = shift;

    my %content = $self->content;

    $self->required_fields( qw/order_number amount currency/ );

    ########### initialize template variables #########

    $self->currency( $content{currency} ) if $content{currency};
    my $currency = $self->currency;

    my $amount_value = $content{amount};

    # amount must be specified with an "exponent"
    # Example: $123.45 would be specified as value = "12345", exponent = "2"

    my $amount_exponent = 2;                # works for all but Indonesian Rupiah

    $amount_value =~ s/,(?=\d\d$)/./g;                  # 123,45    => 123.45
    $amount_value =~ s/,//g;                            # 12,345.46 => 12345.46
    $amount_value =  sprintf "%.2f", $amount_value;     # 123       => 123.00
    $amount_value =~ s/\.//g;                           # 123.00    => 12300

    ########### get XML template for request ##########

    my $xml_template = _get_xml_template( $self->action );

    ########### initialize data for template ##########

    my $template_vars = {
        merchantCode => $self->login,
        version      => $self->version,
        orderCode    => $content{order_number},
        amount       => {
            value        => $amount_value,
            currencyCode => $self->currency,
            exponent     => $amount_exponent,
        },
    };

    return ($xml_template, $template_vars);
}


sub _launder_envariables
{
    my ($installation_id, $merchant_code, $xml_password, $debug);

    if ( $ENV{WORLDPAY_INSTALLATION_ID} ) {                     # must be all digits
        ( $installation_id )  =  $ENV{WORLDPAY_INSTALLATION_ID} =~ m/^ ( \d+ ) $/x;
    }

    if ( $ENV{WORLDPAY_MERCHANT_CODE} ) {                       # must be alphanumeric
        ( $merchant_code )    =  $ENV{WORLDPAY_MERCHANT_CODE}   =~ m/^ ( \w+ ) $/x;
    }

    if ( $ENV{WORLDPAY_XML_PASSWORD} ) {                        # must be alphanumeric
        ( $xml_password )     =  $ENV{WORLDPAY_XML_PASSWORD}    =~ m/^ ( \w+ ) $/x;
    }

    if ( $ENV{WORLDPAY_DEBUG} ) {                               # digits or pathname
        ( $debug )            =  $ENV{WORLDPAY_DEBUG}           =~ m{^ ( \d+ | [-/.\w]+ ) $}x;
    }

    @ENV{qw/
        WORLDPAY_INSTALLATION_ID
        WORLDPAY_MERCHANT_CODE
        WORLDPAY_XML_PASSWORD
        WORLDPAY_DEBUG
    /} = (
        $installation_id || '',
        $merchant_code   || '',
        $xml_password    || '',
        $debug           || '',
    );

    return;
}


sub required_fields
{
    my($self, @fields) = @_;

    my %content = $self->content();

    foreach (@fields) {
#       Carp::croak("missing required field $_") unless exists $content{$_};    # standard B::OP check
        Carp::croak("missing required field $_") unless $content{$_};           # modified for B::OP::WorldPay
    }
}


sub _get_maps
{
    # Culled from the "Submitting Transactions in the Direct Model" document
    # and the WorldPay DTD: http://dtd.worldpay.com/paymentService_v1.dtd

    my %Payment_Methods = (
        'visa' =>        {
            paymentType => 'VISA-SSL',
            _required => [ qw/card_number exp_date name/ ],
        },

        'amex' =>        {
            paymentType => 'AMEX-SSL',
            _required => [ qw/card_number exp_date name/ ],
        },

        'mastercard' =>  {
            paymentType => 'ECMC-SSL',
            _required => [ qw/card_number exp_date name/ ],
        },

        'diners card' => {
            paymentType => 'DINERS-SSL',
            _required => [ qw/card_number exp_date name/ ],
        },

        'solo card' =>   {
            paymentType => 'SOLO_GB-SSL',
            _required => [ qw/card_number exp_date name/ ],

            # from DTD: (issueNumber | (startDate, issueNumber?) )
            # either issue number or start date must be included
            # have to handle as a special case in sub submit
        },

        'maestro' =>     {
            paymentType => 'MAESTRO-SSL',
            _required => [ qw/card_number exp_date name/ ],

            # from DTD: startDate?, issueNumber?
            # issue number and start date both optional (?)
        },

#       'elv' =>         {
#           paymentType => 'ELV-SSL',
#           _required => [ qw/accountHolderName bankAccountNr bankName
#                               bankLocation bankLocationId/ ],
#       },

        'jcb card' =>    {
            paymentType => 'JCB-SSL',
            _required => [ qw/card_number exp_date name/ ],
        },
    );

    $Payment_Methods{diners} = $Payment_Methods{'diners card'};
    $Payment_Methods{jcb}    = $Payment_Methods{'jcb card'};
    $Payment_Methods{solo}   = $Payment_Methods{'solo card'};


    my %XML_Error_Codes = (
        1 => 'Internal Error',
        2 => 'Parse error, invalid XML',
        3 => 'Invalid number of transactions in batch',
        4 => 'Security error',
        5 => 'Invalid request',
        6 => 'Invalid content',
        7 => 'Payment details incorrect',
    );


    return (\%Payment_Methods, \%XML_Error_Codes);
}


sub _get_xml_template
{
    my $action = shift;

    my ($payment_xml, $inquiry_xml, $cancel_xml, $refund_xml, $cancel_or_refund_xml);

    $payment_xml = <<'EOS';
<?xml version="1.0"?>
<!DOCTYPE paymentService PUBLIC
"-//WorldPay/DTD WorldPay PaymentService v1//EN"
"http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd">

<paymentService merchantCode="[% merchantCode %]" version="[% version %]">
<submit>
    <order orderCode="[% orderCode %]" installationId="[% installationId %]">
    <description>[% description %]</description>
    <amount currencyCode="[% amount.currencyCode %]" value="[% amount.value %]" exponent="[% amount.exponent %]" />
    [%- IF orderContent -%]
    <orderContent><![CDATA[ [%- orderContent -%] ]]></orderContent>
    [%- END %]
    <paymentDetails action="[% paymentDetails.action %]">
        <[% paymentDetails.paymentType %]>
        <cardNumber>[% paymentDetails.cardNumber %]</cardNumber>
        <expiryDate>
            <date month="[% paymentDetails.expiryDate.month %]" year="[% paymentDetails.expiryDate.year %]" />
        </expiryDate>
        <cardHolderName>[% paymentDetails.cardHolderName %]</cardHolderName>
        [%- IF paymentDetails.startDate.month && paymentDetails.startDate.year %]
        <startDate>
            <date month="[% paymentDetails.startDate.month %]" year="[% paymentDetails.startDate.year %]" />
        </startDate>
        [%- END -%]
        [%- IF paymentDetails.issueNumber %]
        <issueNumber>[% paymentDetails.issueNumber %]</issueNumber>
        [%- END -%]
        [%- IF paymentDetails.cvc %]
        <cvc>[% paymentDetails.cvc %]</cvc>
        [%- END -%]
        [%- IF paymentDetails.cardAddress.firstName       ||
               paymentDetails.cardAddress.lastName        ||
               paymentDetails.cardAddress.street          ||
               paymentDetails.cardAddress.postalCode      ||
               paymentDetails.cardAddress.countryCode     ||
               paymentDetails.cardAddress.telephoneNumber
        %]
        <cardAddress>
            <address>
            [%- IF paymentDetails.cardAddress.firstName %]
            <firstName>[%       paymentDetails.cardAddress.firstName       %]</firstName>
            [%- END -%]
            [%- IF paymentDetails.cardAddress.lastName %]
            <lastName>[%        paymentDetails.cardAddress.lastName        %]</lastName>
            [%- END -%]
            [%- IF paymentDetails.cardAddress.street %]
            <street>[%          paymentDetails.cardAddress.street          %]</street>
            [%- END -%]
            [%- IF paymentDetails.cardAddress.postalCode.defined %]
            <postalCode>[%      paymentDetails.cardAddress.postalCode      %]</postalCode>
            [%- END -%]
            [%- IF paymentDetails.cardAddress.countryCode %]
            <countryCode>[%     paymentDetails.cardAddress.countryCode     %]</countryCode>
            [%- END -%]
            [%- IF paymentDetails.cardAddress.telephoneNumber %]
            <telephoneNumber>[% paymentDetails.cardAddress.telephoneNumber %]</telephoneNumber>
            [%- END %]
            </address>
        </cardAddress>
        [%- END %]
        </[% paymentDetails.paymentType %]>
        [%- IF session.shopperIPAddress && session.id %]
        <session shopperIPAddress="[% session.shopperIPAddress %]" id="[% session.id %]" />
        [%- END %]
    </paymentDetails>
    [%- IF shopper.acceptHeader && shopper.userAgentHeader %]
    <shopper>
        <browser>
        <acceptHeader>[%    shopper.acceptHeader    %]</acceptHeader>
        <userAgentHeader>[% shopper.userAgentHeader %]</userAgentHeader>
        </browser>
    </shopper>
    [%- END %]
    </order>
</submit>
</paymentService>
EOS

    $inquiry_xml = <<'EOS';
<?xml version="1.0"?>
<!DOCTYPE paymentService PUBLIC
"-//WorldPay/DTD WorldPay PaymentService v1//EN"
"http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd">

<paymentService version="[% version %]" merchantCode="[% merchantCode %]">
<inquiry>
    <orderInquiry orderCode="[% orderCode %]" />
</inquiry>
</paymentService>
EOS

    $cancel_xml = <<'EOS';
<?xml version="1.0"?>
<!DOCTYPE paymentService PUBLIC
"-//WorldPay/DTD WorldPay PaymentService v1//EN"
"http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd">

<paymentService version="[% version %]" merchantCode="[% merchantCode %]">
<modify>
    <orderModification orderCode="[% orderCode %]">
        <cancel/>
    </orderModification>
</modify>
</paymentService>
EOS

    $refund_xml = <<'EOS';
<?xml version="1.0"?>
<!DOCTYPE paymentService PUBLIC
"-//WorldPay/DTD WorldPay PaymentService v1//EN"
"http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd">

<paymentService version="[% version %]" merchantCode="[% merchantCode %]">
<modify>
    <orderModification orderCode="[% orderCode %]">
        <refund>
            <amount
            value="[% amount.value %]"
            currencyCode="[% amount.currencyCode %]"
            exponent="[% amount.exponent %]"
            debitCreditIndicator="credit"
            />
        </refund>
    </orderModification>
</modify>
</paymentService>
EOS

    $cancel_or_refund_xml = <<'EOS';
<?xml version="1.0"?>
<!DOCTYPE paymentService PUBLIC
"-//WorldPay/DTD WorldPay PaymentService v1//EN"
"http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd">

<paymentService version="[% version %]" merchantCode="[% merchantCode %]">
<modify>
    <orderModification orderCode="[% orderCode %]">
        <cancelOrRefund/>
    </orderModification>
</modify>
</paymentService>
EOS

    if ($action eq 'status') {
        return $inquiry_xml;
    }
    elsif ($action eq 'cancel') {
        return $cancel_xml;
    }
    elsif ($action eq 'refund') {
        return $refund_xml;
    }
    elsif ($action eq 'cancel_or_refund') {
        return $cancel_or_refund_xml;
    }
    else {
        return $payment_xml;
    }
}

1;

=head1 NAME

Business::OnlinePayment::WorldPay - RBS WorldPay interface for Business::OnlinePayment

=head1 SYNOPSIS

  use Business::OnlinePayment;

  my $tx = Business::OnlinePayment->new("WorldPay");

  $tx->content(
      installation   => '12345',
      login          => 'testdrive',
      password       => 'xyzzy',

      type           => 'Visa',
      action         => 'payment',   # 'status', 'cancel', 'refund', 'cancel_or_refund'
      description    => '20 English Roses',
      amount         => '49.95',
      currency       => 'GBP',
      order_number   => 'A00100',

      name           => 'Claire Voyance',
      address        => '123 Disk Drive',
      city           => 'Anywhere',
      state          => 'DE',
      zipcode        => '19808',
      country        => 'US',
      phone          => '201-555-1212',

      card_number    => '4007000000027',
      exp_date       => '09/10',
      start_date     => '01/03',
      issue_number   => '002',
      cvc            => '377',
  );


  $tx->set_server('test');    # 'live' (default) or 'test'

  $tx->debug(1);                            # debugging to STDERR
  $tx->debug(1, "/tmp/debugging.outfile");  # debugging output to file

  $tx->test_transaction(1);   # another way to set server to test

  $tx->submit();

  print "server_response = ", $tx->server_response, "\n";

  print "is_success      = ", $tx->is_success,      "\n";

  print "authorization   = ", $tx->authorization,   "\n";
  print "error_message   = ", $tx->error_message,   "\n\n";

  print "result_code     = ", $tx->result_code,     "\n";
  print "status_code     = ", $tx->status_code,     "\n";
  print "status_detail   = ", $tx->status_detail,   "\n";

  print "cvv2_response   = ", $tx->cvv2_response,   "\n";
  print "avs_code        = ", $tx->avs_code,        "\n";
  print "risk_score      = ", $tx->risk_score,      "\n";

  if ($tx->is_success) {
      print "Card processed successfully: " . $tx->authorization . "\n";
  }
  else {
      print "Card was rejected: " . $tx->error_message . "\n";
  }

=cut

=head1 DESCRIPTION

This module subclasses Business::OnlinePayment to provide a basic merchant
processing interface for submitting transactions as XML requests in the
direct model provided by RBS WorldPay.

L<http://www.rbsworldpay.com>

L<http://www.rbsworldpay.com/support/bg/xml/kb/submittingtransactionsdirect/dxml.html>

It currently implements payments, cancellations, refunds, and payment status inquiries.

Orders submitted to the RBS WorldPay system are required to be valid XML
files as specified in their Document Type Definition (DTD):

L<http://dtd.wp3.rbsworldpay.com/paymentService_v1.dtd>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-business-onlinepayment-worldpay at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Business-OnlinePayment-WorldPay>.
I will be notified, and then you'll automatically be notified of progress on your
bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Business::OnlinePayment::WorldPay

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Business-OnlinePayment-WorldPay>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Business-OnlinePayment-WorldPay>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Business-OnlinePayment-WorldPay>

=item * Search CPAN

L<http://search.cpan.org/dist/Business-OnlinePayment-WorldPay>

=back

=head1 SEE ALSO

L<Business::OnlinePayment>

=head1 AUTHOR

Paul Grassie, E<lt>paul.grassie@ardishealth.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 Paul Grassie, Ardis Health, http://www.ardishealth.com. All Rights Reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.
