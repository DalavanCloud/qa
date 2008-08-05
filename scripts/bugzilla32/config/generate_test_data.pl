use strict;
use warnings;

my $conf_path;
my $config; 

BEGIN {
    print "reading the config file...\n";
    my $conf_file = "selenium_test.conf";
    $config = do "$conf_file"
        or die "can't read configuration '$conf_file': $!$@";

    $conf_path = $config->{bugzilla_path};
}

use lib $conf_path;

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::User;
use Bugzilla::Install;
use Bugzilla::Product;
use Bugzilla::Component;
use Bugzilla::Group;
use Bugzilla::Constants;

my $dbh = Bugzilla->dbh;

# set Bugzilla usage mode to USAGE_MODE_CMDLINE
Bugzilla->usage_mode(USAGE_MODE_CMDLINE);

##########################################################################
# Create Users
##########################################################################
# First of all, remove the default .* regexp for the editbugs group.
my $group = new Bugzilla::Group({ name => 'editbugs' });
$group->set_user_regexp('');
$group->update();

my @usernames = (
    'admin',            'no-privs',
    'QA-Selenium-TEST', 'canconfirm',
    'tweakparams',      'permanent_user'
);

print "creating user accounts...\n";
for my $username (@usernames) {

    my $password;
    my $login;
       
    if ($username eq 'permanent_user') {
        $password = $config->{admin_user_passwd};
        $login = $config->{$username};
    }
    elsif ($username eq 'no-privs') {
        $password = $config->{unprivileged_user_passwd};
        $login = $config->{unprivileged_user_login};   
    }
    elsif ($username eq 'QA-Selenium-TEST') {
        $password = $config->{QA_Selenium_TEST_user_passwd};
        $login = $config->{QA_Selenium_TEST_user_login};
    }
    else {
        $password = $config->{"$username" . "_user_passwd"};
        $login = $config->{"$username" . "_user_login"};
    }

    if ( is_available_username($login) ) {
        Bugzilla::User->create(
            {   login_name    => $login,
                realname      => $username,
                cryptpassword => $password,
            }
        );

        if ( $username eq 'admin' or $username eq 'permanent_user' ) {

            Bugzilla::Install::make_admin($login);
        }
    }
}

##########################################################################
# Create Bugs
##########################################################################

# login to bugzilla
my $cgi = Bugzilla->cgi;
$cgi->param( 'Bugzilla_login',    $config->{admin_user_login} );
$cgi->param( 'Bugzilla_password', $config->{admin_user_passwd} );

Bugzilla->login(LOGIN_REQUIRED);

my %field_values = (
    'priority'     => 'P1',
    'bug_status'   => 'NEW',
    'version'      => 'unspecified',
    'bug_file_loc' => '',
    'comment'      => 'please ignore this bug',
    'component'    => 'TestComponent',
    'rep_platform' => 'All',
    'short_desc'   => 'This is a testing bug only',
    'product'      => 'TestProduct',
    'op_sys'       => 'Linux',
    'bug_severity' => 'normal',
);

print "creating bugs...\n";
Bugzilla::Bug->create( \%field_values );
Bugzilla::Bug->create( \%field_values );

##########################################################################
# Create Products
##########################################################################
my @products = (
    {product_name     => 'QA-Selenium-TEST',
        description      => "used by Selenium test.. DON'T DELETE",
        version          => 'unspecified',
        defaultmilestone => '---',
        components       => [
            {   name             => "QA-Selenium-TEST",
                description      => "used by Selenium test.. DON'T DELETE",
                initialowner     => $config->{QA_Selenium_TEST_user_login},
                initialqacontact => $config->{QA_Selenium_TEST_user_login},
                initial_cc       => [$config->{QA_Selenium_TEST_user_login}],

            }
        ],
    },

    {   product_name => 'Another Product',
        description =>
            "Alternate product used by Selenium. <b>Do not edit!</b>",
        version          => 'unspecified',
        defaultmilestone => '---',
        components       => [
            {   name             => "c1",
                description      => "c1",
                initialowner     => $config->{permanent_user},
                initialqacontact => '',
                initial_cc       => [],

            },
            {   name             => "c2",
                description      => "c2",
                initialowner     => $config->{permanent_user},
                initialqacontact => '',
                initial_cc       => [],

            },
        ],
    },
);

print "creating products...\n";
for my $product (@products) {
    if ( !Bugzilla::Product->new( { name => $product->{product_name} } ) ) {

        $dbh->do('INSERT INTO products (name, description) VALUES (?, ?)',
            undef, ( $product->{product_name}, $product->{description} ) );

        my $new_product
            = new Bugzilla::Product( { name => $product->{product_name} } );

        $dbh->do( 'INSERT INTO versions (value, product_id) VALUES (?, ?)',
            undef, ( $product->{version}, $new_product->id ) );

        $dbh->do( 'INSERT INTO milestones (product_id, value) VALUES (?, ?)',
            undef, ( $new_product->id, $product->{defaultmilestone} ) );

        # Now clear the internal list of accessible products.
        delete Bugzilla->user->{selectable_products};

        for my $component ( @{ $product->{components} } ) {

            Bugzilla::Component->create(
                {   name             => $component->{name},
                    product          => $new_product,
                    description      => $component->{description},
                    initialowner     => $component->{initialowner},
                    initialqacontact => $component->{initialqacontact},
                    initial_cc       => $component->{initial_cc},

                }
            );
        }
    }
}

##########################################################################
# Create Groups
##########################################################################
# create Master group
my ( $group_name, $group_desc )
    = ( "Master", "Master Selenium Group <b>DO NOT EDIT!</b>" );

print "creating groups...\n";
if ( !Bugzilla::Group->new( { name => $group_name } ) ) {
    my $group = Bugzilla::Group->create({ name => $group_name,
                                          description => $group_desc,
                                          isbuggroup => 1});

    $dbh->do('INSERT INTO group_control_map
              (group_id, product_id, entry, membercontrol, othercontrol, canedit)
              SELECT ?, products.id, 0, ?, ?, 0 FROM products',
              undef, ( $group->id, CONTROLMAPSHOWN, CONTROLMAPSHOWN ) );
}

# create QA-Selenium-TEST group. Do not use Group->create() so that
# the admin group doesn't inherit membership (yes, that's what we want!).
( $group_name, $group_desc )
    = ( "QA-Selenium-TEST", "used by Selenium test.. DON'T DELETE" );

if ( !Bugzilla::Group->new( { name => $group_name } ) ) {
    $dbh->do('INSERT INTO groups (name, description, isbuggroup, isactive)
              VALUES (?, ?, 1, 1)', undef, ( $group_name, $group_desc ) );
}

##########################################################################
# Add Users to Groups
##########################################################################
my @users_groups = (
    { user => $config->{QA_Selenium_TEST_user_login}, group => 'QA-Selenium-TEST' },
    { user => $config->{tweakparams_user_login},      group => 'tweakparams' },
    { user => $config->{canconfirm_user_login},       group => 'canconfirm' },
);

print "adding users to groups...\n";
for my $user_group (@users_groups) {

    my $group = new Bugzilla::Group( { name => $user_group->{group} } );
    my $user = new Bugzilla::User( { name => $user_group->{user} } );

    my $sth_add_mapping = $dbh->prepare(
        qq{INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
           VALUES (?, ?, ?, ?)});
    # Don't crash if the entry already exists.
    eval {
        $sth_add_mapping->execute( $user->id, $group->id, 0, GRANT_DIRECT );
    };
}

##########################################################################
# Associate Products with groups
##########################################################################
# Associate the QA-Selenium-TEST group with the QA-Selenium-TEST.
my $created_group   = new Bugzilla::Group(   { name => 'QA-Selenium-TEST' } );
my $created_product = new Bugzilla::Product( { name => 'QA-Selenium-TEST' } );

print "restricting products to groups...\n";
# Don't crash if the entry already exists.
eval {
    $dbh->do('INSERT INTO group_control_map
              (group_id, product_id, entry, membercontrol, othercontrol, canedit)
              VALUES (?, ?, ?, ?, ?, ?)',
        undef, ( $created_group->id, $created_product->id, 1, CONTROLMAPMANDATORY,
        CONTROLMAPMANDATORY, 0 ) );
};

print "installation and configuration complete!\n";