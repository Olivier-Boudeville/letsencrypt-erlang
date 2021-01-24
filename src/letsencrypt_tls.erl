%% Copyright 2015-2021 Guillaume Bour
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(letsencrypt_tls).
-author("Guillaume Bour <guillaume@bour.cc>").

-export([ obtain_private_key/2, obtain_dh_key/1,
		  obtain_ca_cert_file/1, obtain_ca_cert_file/2,
		  get_cert_request/3,
		  generate_certificate/5, write_certificate/3,
		  key_to_map/1, map_to_key/1 ]).


-include_lib("public_key/include/public_key.hrl").

% For the records introduced:
-include_lib("letsencrypt.hrl").


% Shorthands:

-type file_path() :: file_utils:file_path().
-type bin_file_path() :: file_utils:bin_file_path().

-type directory_path() :: file_utils:bin_directory_path().
-type bin_directory_path() :: file_utils:bin_directory_path().
-type any_directory_path() :: file_utils:any_directory_path().

-type key_file_info() :: letsencrypt:key_file_info().
-type san() :: letsencrypt:san().
-type bin_certificate() :: letsencrypt:bin_certificate().

-type tls_private_key() :: letsencrypt:tls_private_key().
-type tls_public_key() :: letsencrypt:tls_public_key().

-type certificate_provider() :: letsencrypt:certificate_provider().



% Obtains a private key for the current LEEC agent, either by creating it (in a
% specified filename or in a generated one) or by reading a pre-existing one
% from file.
%
-spec obtain_private_key( maybe( key_file_info() ), bin_directory_path() ) ->
									tls_private_key().
obtain_private_key( _KeyFileInfo=undefined, BinCertDirPath ) ->

	% If not set, forges a unique key filename to allow for multiple, concurrent
	% instances:
	%
	% (ex: "leec-agent.key-5")
	%
	BasePath = file_utils:join( BinCertDirPath, "leec-agent-private.key" ),

	% Should be sufficient to be unique:
	UniqPath = file_utils:get_non_clashing_entry_name_from( BasePath ),

	% Safety measure, not expected to trigger or to be passed in an (always
	% possible) race condition:
	%
	case file_utils:is_existing_file( UniqPath ) of

		true ->
			throw( { already_existing_agent_key, UniqPath } );

		false ->
			ok

	end,

	% Could have been more elegant:
	UniqBinFilename = text_utils:string_to_binary(
					 file_utils:get_last_path_element( UniqPath ) ),

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "[~w] Generated filename for the LEEC agent "
			"private key: '~s'.", [ self(), UniqBinFilename ] ) ),

	obtain_private_key( { new, UniqBinFilename }, BinCertDirPath );


obtain_private_key( _KeyFileInfo={ new, BinKeyFilename }, BinCertDirPath ) ->

	KeyFilePath = file_utils:join( BinCertDirPath, BinKeyFilename ),

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "[~w] A private key is to be created in '~s'.",
								[ self(), KeyFilePath ] ) ),

	case file_utils:is_existing_file( KeyFilePath ) of

		true ->
			% The user code shall remove any prior key first if wanting to avoid
			% this warning:
			%
			trace_bridge:warning_fmt( "A '~s' key file was already existing, "
				"overwriting it.", [ KeyFilePath ] );

		false ->
			ok

	end,

	Cmd = executable_utils:get_default_openssl_executable_path()
		++ " genrsa -out '" ++ KeyFilePath ++ "' 4096",

	case system_utils:run_executable( Cmd ) of

		{ _ReturnCode=0, _CommandOutput="" } ->
			ok;

		% Not deserving a warning, as returning in case of success: "Generating
		% RSA private key, 4096 bit long modulus (2 primes) [...]".
		%
		{ _ReturnCode=0, CommandOutput } ->
			cond_utils:if_defined( leec_debug_keys,
				trace_bridge:debug_fmt( "Private key creation successful; "
					"following output was made: ~s.", [ CommandOutput ] ),
				basic_utils:ignore_unused( CommandOutput ) );

		{ ErrorCode, CommandOutput } ->
			trace_bridge:error_fmt(
			  "Command for creating private key failed (error code: ~B): ~s.",
			  [ ErrorCode, CommandOutput ] ),
			throw( { private_key_generation_failed, ErrorCode, CommandOutput,
					 KeyFilePath } )

	end,

	case file_utils:is_existing_file( KeyFilePath ) of

		true ->
			ok;

		false ->
			throw( { generated_private_key_not_found, KeyFilePath } )

	end,

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "[~w] Creation of private key in '~s' "
			"succeeded.", [ self(), KeyFilePath ] ) ),

	% Now load it (next clause), and return it as a tls_private_key():
	obtain_private_key( KeyFilePath, BinCertDirPath );


obtain_private_key( _KeyFileInfo=KeyFilePath, BinCertDirPath ) ->

	FullKeyFilePath = file_utils:ensure_path_is_absolute( KeyFilePath,
								_PotentialBasePath=BinCertDirPath ),

	PemContent = file_utils:read_whole( FullKeyFilePath ),

	% A single ASN.1 DER encoded entry expected:
	KeyEntry = case public_key:pem_decode( PemContent ) of

		[ KeyEnt ] ->
			KeyEnt;

		[] ->
			throw( { no_asn_der_entry_in, PemContent } );

		KeyEntries ->
			throw( { multiple_asn_der_entries_in, PemContent, KeyEntries } )

	end,

	#'RSAPrivateKey'{ modulus=N, publicExponent=E, privateExponent=D } =
		public_key:pem_entry_decode( KeyEntry ),

	PrivKey = #tls_private_key{
	   raw=[ E, N, D ],
	   b64_pair={ letsencrypt_utils:b64encode( binary:encode_unsigned( N ) ),
				  letsencrypt_utils:b64encode( binary:encode_unsigned( E ) ) },
	   file_path=text_utils:ensure_binary( FullKeyFilePath ) },

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "[~w] Returning following private key:~n  ~p",
								[ self(), PrivKey ] ) ),

	PrivKey.



% Secures a proper DH file for safer key exchange, creates it only if necessary,
% returns its path.
%
% The Ephemeral Diffie-Helman key exchange is a very effective way of ensuring
% Forward Secrecy by exchanging a set of keys that never hit the wire.
%
-spec obtain_dh_key( directory_path() ) -> bin_file_path().
obtain_dh_key( CertDir ) ->

	% Conventional:
	DHFilename = "dh-params.pem",

	DhFilePath = file_utils:join( CertDir, DHFilename ),

	BinDhFilePath = text_utils:string_to_binary( DhFilePath ),

	case file_utils:is_existing_file_or_link( DhFilePath ) of

		true ->
			trace_bridge:info_fmt(
				"A DH file was found already existing (as '~s'), not "
				"recreating it.", [ DhFilePath ] ),
			BinDhFilePath;

		false ->
			trace_bridge:warning_fmt( "No DH file found (no '~s'), "
				"creating it; note that it is a longer operation.",
				[ DhFilePath ] ),

			Cmd = executable_utils:get_default_openssl_executable_path()
				++ " dhparam -out '" ++ DhFilePath ++ "' 3072",

			case system_utils:run_executable( Cmd ) of

				{ _ReturnCode=0, _CommandOutput="" } ->
					 ok;

				% Not deserving a warning, as returning in case of success:
				% "Generating DH parameters, 2048 bit long safe prime, [...]".
				%
				% Unconditionally emitted due to the longer duration:
				{ _ReturnCode=0, CommandOutput } ->
					trace_bridge:info_fmt( "DH key creation successful; "
						 "following output was made: ~s.", [ CommandOutput ] );

				{ ErrorCode, CommandOutput } ->
					trace_bridge:error_fmt( "Command for creating private key "
						"failed (error code: ~B): ~s.",
						[ ErrorCode, CommandOutput ] ),
					throw( { dh_key_generation_failed, ErrorCode, CommandOutput,
							 DhFilePath } )

			end,

			case file_utils:is_existing_file( DhFilePath ) of

				true ->
					BinDhFilePath;

				false ->
					throw( { generated_dh_key_not_found, DhFilePath } )

			end

	end.



% Obtains the intermediate certificate of the default authority.
-spec obtain_ca_cert_file( any_directory_path() ) -> bin_file_path().
obtain_ca_cert_file( TargetDir ) ->
	obtain_ca_cert_file( TargetDir, _DefaultProvider=letsencrypt ).


% Obtains the intermediate certificate of the specified authority.
-spec obtain_ca_cert_file( any_directory_path(), certificate_provider() ) ->
			file_path().
obtain_ca_cert_file( TargetDir, _CertProvider=letsencrypt ) ->

	CAUrl = "https://letsencrypt.org/certs/lets-encrypt-r3-cross-signed.pem",

	Filename = web_utils:get_last_path_element( CAUrl ),

	FilePath = file_utils:join( TargetDir, Filename ),

	case file_utils:is_existing_file_or_link( FilePath ) of

		true ->

			trace_bridge:info_fmt(
				"Certificate authority certificate file was found already "
				"existing (as '~s'), not downloading it.", [ FilePath ] ),

			text_utils:string_to_binary( FilePath );

		false ->

			trace_bridge:info_fmt( "No certificate authority certificate "
				"file found (no '~s'), downloading it from ~s.",
				[ FilePath, CAUrl ] ),

			% Expected to be equal to FilePath:
			ResFilePath = web_utils:download_file( CAUrl, TargetDir ),

			text_utils:string_to_binary( ResFilePath )

	end.



% Returns a CSR certificate request.
-spec get_cert_request( net_utils:bin_fqdn(), bin_directory_path(),
						[ san() ] ) -> letsencrypt:tls_csr().
get_cert_request( BinDomain, BinCertDirPath, SANs ) ->

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "[~w] Generating certificate request for '~s', "
			"with SANs: ~s",
			[ self(), BinDomain, text_utils:strings_to_string( SANs ) ] ) ),

	Domain = text_utils:binary_to_string( BinDomain ),

	KeyFilePath = file_utils:join( BinCertDirPath, Domain ++ ".key" ),

	CertFilePath = file_utils:join( BinCertDirPath, Domain ++ ".csr" ),

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "CSR file path: '~s'.", [ CertFilePath ] ) ),

	generate_certificate( request, BinDomain, CertFilePath, KeyFilePath, SANs ),

	RawCsr = file_utils:read_whole( CertFilePath ),

	[ { 'CertificationRequest', Csr, not_encrypted } ] =
		public_key:pem_decode( RawCsr ),

	% Not relevant, an opaque binary:
	%cond_utils:if_defined( leec_debug_keys,
	%	trace_bridge:debug_fmt( "Decoded CSR:~n  ~p.", [ Csr ] ) ),

	letsencrypt_utils:b64encode( Csr ).



% Generates the specified certificate with subjectAlternativeName, either an
% actual one, or a temporary (1 day), autosigned one.
%
-spec generate_certificate( 'request' | 'autosigned', net_utils:bin_fqdn(),
						file_path(), file_path(), [ san() ] ) -> void().
generate_certificate( CertType, BinDomain, OutCertPath, KeyfilePath, SANs ) ->

	% First, generates a configuration file, in the same directory as the target
	% certificate:

	AllNames = [ BinDomain | SANs ],

	% {any_string(), basic_utils:count()} pairs:
	NumberedNamePairs = lists:zip( AllNames,
								   lists:seq( 1, length( AllNames ) ) ),

	ConfDataStr = [
		"[req]\n",
		"distinguished_name = req_distinguished_name\n",
		"x509_extensions = v3_req\n",
		"prompt = no\n",
		"[req_distinguished_name]\n",
		"CN = ", BinDomain, "\n",
		"[v3_req]\n",
		"subjectAltName = @alt_names\n",
		"[alt_names]\n"
	] ++ [
		[ "DNS.", text_utils:integer_to_string( Index ), " = ", Name, "\n" ]
		  || { Name, Index } <- NumberedNamePairs ],

	ConfDir = file_utils:get_base_path( OutCertPath ),

	Domain = text_utils:binary_to_string( BinDomain ),

	ConfFilePath = file_utils:join( ConfDir,
						"letsencrypt_san_openssl." ++ Domain ++ ".cnf" ),

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "Generating a certificate from '~s', in '~s', "
			"based on following SAN names: ~s", [ ConfFilePath, OutCertPath,
				text_utils:strings_to_string( AllNames ) ] ) ),

	file_utils:write_whole( ConfFilePath, ConfDataStr ),

	CertTypeOptStr = case CertType of

		request ->
			" -reqexts v3_req";

		autosigned ->
			" -extensions v3_req -x509 -days 1"

	end,

	Cmd = text_utils:format(
			"~s req -new -key '~s' -sha256 -out '~s' -config '~s'",
			[ executable_utils:get_default_openssl_executable_path(),
			  KeyfilePath, OutCertPath, ConfFilePath ] ) ++ CertTypeOptStr,

	case system_utils:run_executable( Cmd ) of

		{ _ReturnCode=0, _CommandOutput="" } ->
			ok;

		{ _ReturnCode=0, CommandOutput } ->
			trace_bridge:warning_fmt(
			  "Command output when generating certificate: ~s",
			  [ CommandOutput ] );

		{ ErrorCode, CommandOutput } ->
			trace_bridge:error_fmt(
			  "Command for generating certificate failed (error code: ~B): ~s",
			  [ ErrorCode, CommandOutput ] ),
			throw( { certificate_generation_failed, ErrorCode, CommandOutput } )

	end,

	file_utils:remove_file( ConfFilePath ).



% Writes specified certificate, overwriting any prior one.
%
% Domain certificate only.
%
-spec write_certificate( net_utils:string_fqdn(), bin_certificate(),
						 bin_directory_path() ) -> file_path().
write_certificate( Domain, BinDomainCert, BinCertDirPath ) ->

	CertFilePath = file_utils:join( BinCertDirPath, Domain ++ ".crt" ),

	cond_utils:if_defined( leec_debug_keys,
		trace_bridge:debug_fmt( "Writing certificate for domain '~s' "
			"in '~s':~n  ~p.", [ Domain, CertFilePath, BinDomainCert ] ) ),

	% For example in case of renewal:
	file_utils:remove_file_if_existing( CertFilePath ),

	file_utils:write_whole( CertFilePath, BinDomainCert ),

	CertFilePath.



% Returns a map-based version of the specified public key record, typically for
% encoding.
%
-spec key_to_map( tls_public_key() ) -> map().
key_to_map( #tls_public_key{ kty=Kty, n=N, e=E } ) ->
	#{ <<"kty">> => Kty, <<"n">> => N, <<"e">> => E }.


% Return the key record corresponding to the specified map, typically obtained
% from a remote server.
%
-spec map_to_key( map() ) -> tls_public_key().
map_to_key( Map ) ->

	% Ensures all keys are extracted (using one of our map primitives):
	{ [ Kty, N, E ], _RemainingTable=#{} } = map_hashtable:extract_entries(
							   [ <<"kty">>, <<"n">>, <<"e">> ], Map ),

	#tls_public_key{ kty=Kty, n=N, e=E }.
