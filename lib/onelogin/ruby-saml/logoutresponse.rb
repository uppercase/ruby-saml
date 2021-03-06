require "xml_security"
require "time"
require "base64"
require "zlib"
require "open-uri"

module Onelogin
  module Saml
    class Logoutresponse

      ASSERTION = "urn:oasis:names:tc:SAML:2.0:assertion"
      PROTOCOL  = "urn:oasis:names:tc:SAML:2.0:protocol"

      # For API compability, this is mutable.
      attr_accessor :settings

      attr_reader :document
      attr_reader :options
      attr_reader :response
      attr_reader :raw_response
      attr_reader :in_response_to, :issuer

      #
      # In order to validate that the response matches a given request, append
      # the option:
      #   :matches_request_id => REQUEST_ID
      #
      # It will validate that the logout response matches the ID of the request.
      # You can also do this yourself through the in_response_to accessor.
      #
      def initialize(response, settings = nil, options = {})
        raise ArgumentError.new("Logoutresponse cannot be nil") if response.nil?
        self.settings = settings

        @options = options
        @raw_response = response

        parse_logoutresponse
      end

      def validate!
        validate(false)
      end

      def validate(soft = true)
        return false unless valid_saml?(soft) && valid_state?(soft)

        valid_in_response_to?(soft) && valid_issuer?(soft) && success?(soft)
      end

      def success?(soft = true)
        unless @status_code == "urn:oasis:names:tc:SAML:2.0:status:Success"
          return soft ? false : validation_error("Bad status code. Expected <urn:oasis:names:tc:SAML:2.0:status:Success>, but was: <#@status_code> ")
        end
        true
      end

      private

      # TODO: move these to a helper?
      def decode(encoded)
        Base64.decode64(encoded)
      end
      def inflate(deflated)
        zlib = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        zlib.inflate(deflated)
      end

      # TODO: This is pretty ugly... Mimic an applicative functor?
      def parse_samlresponse!
        return if @response =~ /^</

        if raw_response =~ /^</
          @response = raw_response
        else
          @response = ((decoded = decode(raw_response)) =~ /^</) ? decoded : inflate(decoded)
        end

        raise Exception.new("Couldn't decode SAMLResponse") unless @response =~ /^</
      end

      def parse_logoutresponse
        parse_samlresponse!

        begin
          @document = XMLSecurity::SignedDocument.new(response)
        rescue REXML::ParseException => e
          raise e
        end

        @in_response_to ||= begin
          node = REXML::XPath.first(document, "/p:LogoutResponse", { "p" => PROTOCOL, "a" => ASSERTION })
          node.nil? ? nil : node.attributes['InResponseTo']
        end
        @issuer ||= begin
          node = REXML::XPath.first(document, "/p:LogoutResponse/a:Issuer", { "p" => PROTOCOL, "a" => ASSERTION })
          node ||= REXML::XPath.first(document, "/p:LogoutResponse/a:Assertion/a:Issuer", { "p" => PROTOCOL, "a" => ASSERTION })
          node.nil? ? nil : node.text
        end
        @status_code ||= begin
          node = REXML::XPath.first(document, "/p:LogoutResponse/p:Status/p:StatusCode", { "p" => PROTOCOL, "a" => ASSERTION })
          node.nil? ? nil : node.attributes["Value"]
        end
      end

      def valid_saml?(soft = true)
        Dir.chdir(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'schemas'))) do
          @schema = Nokogiri::XML::Schema(IO.read('saml20protocol_schema.xsd'))
          @xml = Nokogiri::XML(self.document.to_s)
        end
        if soft
          @schema.validate(@xml).map{ return false }
        else
          @schema.validate(@xml).map{ |error| raise(Exception.new("#{error.message}\n\n#{@xml.to_s}")) }
        end
      end

      def valid_state?(soft = true)
        if response.empty?
          return soft ? false : validation_error("Blank response")
        end

        if settings.nil?
          return soft ? false : validation_error("No settings on response")
        end

        if settings.issuer.nil?
          return soft ? false : validation_error("No issuer in settings")
        end

        if settings.idp_cert_fingerprint.nil? && settings.idp_cert.nil?
          return soft ? false : validation_error("No fingerprint or certificate on settings")
        end

        true
      end

      def valid_in_response_to?(soft = true)
        return true unless self.options.has_key? :matches_request_id

        unless self.options[:matches_request_id] == in_response_to
          return soft ? false : validation_error("Response does not match the request ID, expected: <#{self.options[:matches_request_id]}>, but was: <#{in_response_to}>")
        end

        true
      end

      def valid_issuer?(soft = true)
        unless URI.parse(issuer) == URI.parse(self.settings.issuer)
          return soft ? false : validation_error("Doesn't match the issuer, expected: <#{self.settings.issuer}>, but was: <#{issuer}>")
        end
        true
      end

      def validation_error(message)
        raise ValidationError.new(message)
      end
    end
  end
end