# Integracja aplikacji Railsowej z system obsługującym płatności w sieci.
# Aktualna wersja obsługuje tylko http://platnosci.pl może z czasem pojawią
# się konektory do innych systemów.
#
# Przed pierwszym użyciem connector musi zostać odpowiednio skonfigurowany.
# Obowiązkowe są parametry pos_id, key1, key2 wszystkie do odczytania z konfiguracji
# POSa w panelu administracyjnym.
# Klucz autoryzacji płatności pos_auth_key przy tworzeniu transakcji nie jest obowiązkowy tylko gdy weryfikacja po pos_auth_key jest wyłączona z poziomu aplikacji.
# Wyłączyć tą opcję mogą tylko pracownicy BOK. Jest to działanie niezalecane.
# Przyklad konfiguracji:
# TransactionSupport.config.key1 = '...'
# TransactionSupport.config.key2 = '...'
# TransactionSupport.config.pos_id = '...'
# TransactionSupport.config.pos_auth_key = '...'
# TransactionSupport.config.check_report_sig = '...'
# W pliku konfiguracyjnym environment.rb mozna dodatkowo wywolac
# TransactionSupport.validate_config aby sprawdzić poprawność konfigruacji.
# Metoda zglosi wyjatek gdy konfiguracja będzie blędna lub niepełna.
#
# Author:: Daniel Owsianski (daniel-at-jarmark-dot-org)
module TransactionSupport
  class TransactionSupportError < StandardError; end;

  class Configuration
    @@configuration = Rails::OrderedOptions.new
    @@connector = nil

    protected
    def self.config
      @@configuration
    end

    def self.connector
      @@connector ||= PlatnosciPl::Connector.new(@@configuration)
    end
  end

  # Implementacja komunikacji z platnosci.pl
  module PlatnosciPl
    HOST = 'www.platnosci.pl'.freeze
    PORT = 443
    GET_PAYMENT = '/paygw/%s/Payment/get/txt'.freeze
    NEW_PAYMENT = '/paygw/%s/NewPayment'.freeze
    PAYTYPE_JS  = '/paygw/%s/js/%s/paytype.js'.freeze
    # pierwszy encoding z tej tablicy jest traktowany jako domyslny
    ENCODINGS = %w{UTF ISO WIN}.freeze

    PROTOCOL_HOST = 'https://www.platnosci.pl'.freeze
    ERRORS = {
      '100' => 'brak lub błędna wartość parametru pos id',
      '101' => 'brak parametru session id',
      '102' => 'brak parametru ts',
      '103' => 'brak lub błędna wartość parametru sig',
      '104' => 'brak parametru desc',
      '105' => 'brak parametru client ip',
      '106' => 'brak parametru first name',
      '107' => 'brak parametru last name',
      '108' => 'brak parametru street',
      '109' => 'brak parametru city',
      '110' => 'brak parametru post code',
      '111' => 'brak parametru amount',
      '112' => 'błędny numer konta bankowego',
      '113' => 'brak parameteru email',
      '114' => 'brak numeru telefonu',
      '200' => 'inny chwilowy błąd',
      '201' => 'inny chwilowy błąd bazy danych',
      '202' => 'Pos o podanym identyfikatorze jest zablokowany',
      '203' => 'niedozwolona wartość pay_type dla danego pos_id',
      '204' => 'podana metoda płatności (wartość pay_type) jest chwilowo zablokowana dla danego pos_id, np. przerwa konserwacyjna bramki płatniczej',
      '205' => 'kwota transakcji mniejsza od wartości minimalnej',
      '206' => 'kwota transakcji większa od wartości maksymalnej',
      '207' => 'przekroczona wartość wszystkich transakcji dla jednego klienta w ostatnim przedziale czasowym',
      '208' => 'POS dziala w wariancie ExpressPayment lecz nie nastąpiła aktywacja tego wariantu współpracy (czekamy na zgodę działu obsługi klienta)',
      '209' => 'błędny numer pos id lub pos auth key',
      '500' => 'transakcja nie istnieje',
      '501' => 'brak autoryzacji dla danej transakcji',
      '502' => 'transakcja rozpoczęta wcześniej',
      '503' => 'autoryzacja do transakcji była juz przeprowadzana',
      '504' => 'transakcja anulowana wczesniej',
      '505' => 'transakcja przekazana do odbioru wcześniej',
      '506' => 'transakcja już odebrana',
      '507' => 'błąd podczas zwrotu środków do klienta',
      '599' => 'błędny stan transakcji, np. nie można uznać transakcji kilka razy lub inny, prosimy o kontakt',
      '999' => 'inny błąd krytyczny - prosimy o kontakt'
    }.freeze
    STATUSES ={
      '1' => 'nowa',
      '2' => 'anulowana',
      '3' => 'odrzucona',
      '4' => 'rozpoczęta',
      '5' => 'oczekuje na odbiór',
      '6' => 'autoryzacja odmowna',
      '7' => 'płatność odrzucona',
      '99' => 'zakończona',
      '888' => 'błędny status'
    }.freeze
    HEADERS = {'User-Agent' =>'RubyWay!'}.freeze
    RESP_ALLOWED_KEYS=['status', 'trans_status', 'trans_session_id', 'trans_order_id', 'trans_id', 'trans_pay_type', 'trans_pay_gw_name', 
      'trans_amount', 'trans_desc', 'trans_sig', 'error_nr', 'error_message'].freeze

    class Connector
      attr_reader :new_payment_url
      def initialize(config)
        self.validate_config(config)
        @parameters = config
        @encoding = @parameters.encoding || ENCODINGS.first

        @get_payment = GET_PAYMENT % @encoding
        @new_payment_url = PROTOCOL_HOST+(NEW_PAYMENT % @encoding)
      end

      # Sprawdzenei czy mam wszystkie parametry jakie sa potrzebne do komunikacji z platnosci.pl
      def validate_config(config)
        raise TransactionSupportError, "Parameter 'key1' is required" if config.key1.blank?
        raise TransactionSupportError, "Parameter 'key2' is required" if config.key2.blank?
        raise TransactionSupportError, "Parameter 'pos_id' is required" if config.pos_id.nil? || config.pos_id.to_a.empty?
        raise TransactionSupportError, "Parameter 'pos_auth_key' is required" if config.pos_auth_key.blank?
        raise TransactionSupportError, "Unrecognized encoding '#{config.encoding}' valid encoding values: #{ENCODINGS.inspect}" if config.encoding && !ENCODINGS.include?(config.encoding)
      end

      def paytype_js_src(pos_id)
        @paytype_js_src||= begin
          js_path=[(pos_id||@parameters.pos_id.to_a.first), @parameters.key1.to_s[0..1]].join('/')
          PROTOCOL_HOST+(PAYTYPE_JS % [@encoding, js_path])
        end
      end

      # ::options:: jezeli hash to wyszukiwane sa w nim potrzebne parametry,
      #            jezeli string to jest traktowany jako trans_session_id
      # ::pos_id:: jezeli != nil to jest sprawdzany czy jest znany i nadpisuje ten z hasha
      def get_state(options, pos_id=nil)
        raise TransactionSupportError, "Given pos_id='#{pos_id}' is not valid" if pos_id && !@parameters.pos_id.to_a.include?(pos_id.to_s)
        raise TransactionSupportError, "Transaction session parameter is empty" if options.nil? || options.kind_of?(String) && options.blank?

        session_id = options.to_s
        if options.kind_of?(Hash)
          check_hash_options(options)
          session_id = options[:session_id]
        end

        data = prepare_request_data(session_id, pos_id)
        result = nil

        init_http.start do |http|
          req = Net::HTTP::Post.new(@get_payment, HEADERS)
          req.set_form_data(data.stringify_keys)
          response = http.request(req)

          if response.code == '200'
            # nie uzywam YAMLa z powodu potencjalnych bledow w parsowaniu szczegoly opisane w komentarzu do parse_body
            body = parse_body(response.body, RESP_ALLOWED_KEYS)
            result = PaymentState.new(body)

            if config.check_report_sig 
              ts = calculate_ts
              sr = sign_report(pos_id, session_id, result.order_id, result.status, result.amount, result.desc, ts, @parameters.key2)
              puts sr
            end

          else
            raise TransactionSupportError, "Wrong response code='#{response.code}'"
          end
        end
        result
      end

      def error(error_code)
        ERRORS[error_code.to_s]
      end

      protected
      # Sprawdzenie parametrow zawartych w hashu. Najczesciej beda to parametry pochodzace z
      # wywolania zwrotnego z platnosci.pl, sprawdzeniu wiec podlega tez min podpis
      def check_hash_options(options)
        raise TransactionSupportError, "Options is nil" if options.nil?
        opt = options.kind_of?(::HashWithIndifferentAccess) ? options : options.symbolize_keys

        [:pos_id, :session_id, :ts, :sig].each do |key|
          raise TransactionSupportError, "There is no value for key='#{key}'" unless options.has_key?(key.to_s)
        end
        # sprawdzenie czy pos_id jest mi znany
        raise TransactionSupportError, "Given pos_id='#{opt[:pos_id]}' is not valid"  unless @parameters.pos_id.to_a.include?(opt[:pos_id])

        # sprawdzenie poprawnosci podpisu
        local_sign = sign(opt[:pos_id], opt[:session_id], opt[:ts], @parameters.key2)
        raise TransactionSupportError, "Wrong sign" if local_sign!=opt[:sig]
      end

      # Utworzenie danych do wyslania jako parametr dla funkcji Payment/get w platnosci.pl
      # Jezeli pos_id nie jest podany - wybierany jest pierwszy ze skonfigurowanych pos_id
      def prepare_request_data(session_id, pos_id)
        pos = pos_id || @parameters.pos_id.to_a.first

        ts = calculate_ts

        data = {
          :pos_id => pos,
          :session_id => session_id,
          :ts => ts,
          :sig => sign(pos, session_id, ts, @parameters.key1)
        }
        data
      end

      def sign(pos_id, session_id, ts, key)
        Digest::MD5.hexdigest("#{pos_id}#{session_id}#{ts}#{key}")
      end

      # Sygnarura dla danych odesłanych przez platnosci.pl na url raportu
      def sign_report(pos_id, session_id, order_id, status, amount, desc, ts, key2)
        Digest::MD5.hexdigest("#{pos_id}#{session_id}#{order_id}#{status}#{amount}#{desc}#{ts}#{key2}")
      end

      def calculate_ts
         # tak zeby odpowiadalo ts z platnosci czyli javowe z dokladnoscia do ms,
        (Time.now.to_f*1000).to_i
      end

      # Inicjalizacja HTTP, jako osobna metoda upraszcza testowanie
      def init_http
        http = Net::HTTP.new(HOST, PORT)
        http.use_ssl = true
        http.set_debug_output(@parameters.http_debug_stream) if @parameters.http_debug_stream
        http
      end

      # Parsowanie odpowiedzi z platnosci.pl
      # Odpowiedz jest w formacie textowym, wygladajacym jak propertiesy z Javy, albo hash yamlowy
      # Niestety nie mozna wykorzystac parsera YAML bo zdarzaja sie wpisy w postaci np:
      # error_message: NumberFormatException For input string: "pos1"
      # (jezeli pos_id bedzie mial nie liczbowa postac), taki string nie przechodzi przez parser
      # yamla (przyczyna to drugi znak ':' po slowie string).
      #
      # Poniewaz analiza odpowiedzi z platnosci jest kluczowa wiec realizowana jest za pomca
      # starych dobrych regexpw.
      # ::body:: Content zawartosci zwrocony przez platnosci.pl
      # ::allowed_only:: Tablica stringow ktore sa wyszukiwane w body i zwracane w wyniku jako hash.
      #                  Jezeli nil to zwracane jest wszystko co sie da przeparsowac
      def parse_body(body, allowed_only=nil)
        result = {}
        return result if body.blank?
        body.each_line do |line|
          line.strip!
          unless line.blank?
            # uzyty pattern powoduje podzial na 3 czesci: pierwsza to "",
            # druga to key, trzecia value (pierwsza "" wynika z obecnosci znaku spec. ^)
            tokens = line.split(/^(\w+):/)
            key = tokens[1]
            if allowed_only.nil? || allowed_only.include?(key)
              # moze nie byc tokens[2] jezeli w linia wyglada np tak: >key:<
              value = tokens[2]
              value && value.strip!
              value=nil if value.blank?
              result[key]=value
            end
          end
        end
        result
      end
    end


    # Obiekty tego typu sa zwracane jako wynik dzialania metody get_state
    # Zawieraja one wszystkie przeslane informacje o transakcji.
    # Klasa to rozszerzenie zwyklego Hasha o dodatkowe funkcje wpomagajace diagnostyke transakcji
    class PaymentState < Hash
      def initialize(hash)
        super()
        merge!(hash)
      end

      #-- Stany transakcji pogrupowane w trzy 'meta' stany new, received, cancelled
      # Transakcja rozpoczeta - pierwszy status zwracany przez platnosci.pl
      def new?
        self['trans_status']=='1'
      end

      # Platnosc zakonczona sukcesem - pieniadze sa na koncie
      def received?
        self['trans_status']=='99'
      end

      # Transakcja zostala anulowana - znaczy trzeba generowac nowe trans_session_id
      def cancelled?
        ['2', '3', '6', '7', '888'].include?(self['trans_status'])
      end

      #-- Metody ulatwiajace dostep do parametrow pobranych z platnosci.pl
      def trans_status_textual
        STATUSES[self['trans_status']]
      end
      def order_id
        self['trans_order_id']
      end


      # Jezeli platnosci zglosily blad transmisji (najczęsciej spowodowany zlymi parametrami)
      def error?
        self['status']=='ERROR'
      end

      # Wyjasnienie kodu bledu
      def error
        ERRORS[error_code]
      end
      def error_code
        self['error_nr']
      end
      def error_details
        self['error_message']
      end
    end

    # Metody pomocnicze w view.
    # W helperze który ma być rozszerzony trzeba dodac:
    # include TransactionSupport::PlatnosciPl::ViewHelper
    module ViewHelper
      # Adres dla action formularza do skladania zamowien
      def new_payment_url
        Configuration.connector.new_payment_url
      end

      # Zaciagniecie pliku JS z funkcjami do wyboru rodzaju platnosci bezposrednio z serwera platnosci.pl
      # == Parametry
      # ::pos_id - opcjonalny idik posa jezeli nie podany brany jest pod uwagę pierwszy z konfiguracji
      def include_javascript_paytype(pos_id = nil)
        javascript_include_tag Configuration.connector.paytype_js_src(pos_id)
      end
    end
  end

  # -- Publiczne API TransactionSupport

  # Dostep do opcji konfiguracyjnych - do wykorzystaniu przy inicjalizacji
  def self.config
    Configuration.config
  end

  # Mozliwosc sprawdzenia czy parametry konfiguracyjne sa poprawne dla
  # aktualnie uzywanego connectora
  def self.validate_config
    Configuration.connector.validate_config(Configuration.config)
  end

  # Odczytanie statusu zadanej platnosci
  # params moze byc hashem wowczas wyszukuje tam informacje niezbedne dla
  # wykonania operacji, moze byc tez stringiem  wowczas traktowane jest
  # jako trans_session_id.
  # Jezeli podany jest pos_id jest weryfikowany z posami podanymi w konfiguracji
  def self.get_state(params, pos_id=nil)
    Configuration.connector.get_state(params, pos_id)
  end

  # Wyjasnienie opisowe co oznacza dany kod bledu
  def self.error_message(error_code)
    Configuration.connector.error(error_code)
  end
end