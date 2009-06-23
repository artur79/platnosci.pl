require File.dirname(__FILE__) + '/stolen/ordered_options'
require File.dirname(__FILE__) + '/stolen/blank'
require File.dirname(__FILE__) + '/stolen/indifferent_access'
require File.dirname(__FILE__) + '/stolen/hash'
require File.dirname(__FILE__) + '/../init'
require 'digest/md5'
require 'test/unit'

require 'rubygems'
require 'flexmock'


include TransactionSupport
class TransactionSupportTest < Test::Unit::TestCase
    include FlexMock::TestCase

    # Testy validatora konfiguracji
    def test_configuration_validator
        tester = lambda do |msg|
            begin
                TransactionSupport.validate_config
            rescue => e
                assert_kind_of TransactionSupport::TransactionSupportError, e
                assert e.message.include?(msg)
            end
        end
        TransactionSupport.config.clear
        tester.call('key1')
        TransactionSupport.config.key1='test-key1'
        tester.call('key2')
        TransactionSupport.config.key2='test-key2'
        tester.call('pos_id')
        TransactionSupport.config.pos_id='my_pos_id'

        TransactionSupport.config.clear
        tester.call('key1')

        # konfiguracja z kilkoma posami
        TransactionSupport.config.key1='test-key1'
        TransactionSupport.config.key2='test-key1'
        TransactionSupport.config.pos_id=%w{pos1 pos2 pos3}
        TransactionSupport.validate_config
        assert_kind_of Array, TransactionSupport.config.pos_id
    end

    # Testy parsera zawartosci bedacej wynikiem komunikacji z platnosci.pl
    def test_parse_body
        config = OrderedOptions.new
        config.key1='test-key1'
        config.key2='test-key1'
        config.pos_id=['pos-id', 'POS2']
        connector = PlatnosciPl::Connector.new(config)
        class<< connector
            public :parse_body
        end
        # Zestaw danych testowych dla parsera:
        # - body to string symulujacy response.body,
        # - expected to hash oczekiwany jako wynik parsowania
        # - allowed to tablica z kluczami ktore beda przeniesione z body do hasha wyjsciowego
        #   (pozwala to na odfiltrowanie czesci danych z response)
        [
        {
            :body =>"\tkey1:   \tvalue\n\r\nkey2: val2:val3:\tval4\r\n",
            :expected =>{'key1'=>'value', 'key2'=>"val2:val3:\tval4"}
        },{
            :body =>"\tkey1:   \tvalue\n\r\nkey2: val2:val3:\tval4\r\n",
            :allowed=>['key2'],
            :expected =>{'key2'=>"val2:val3:\tval4"}
        },{
            :body =>"\tkey1:   \tvalue\n\r\nkey2: val2:val3:\tval4\r\n",
            :allowed=>['NOEXISTS'],
            :expected =>{}
        },{
            :body =>"key_number1:value1\r\t\n\tkey_2: 2005-12-12 12:23",
            :allowed=>['key_number1', 'key_2'],
            :expected =>{'key_number1'=>"value1", 'key_2'=>'2005-12-12 12:23'}
        },{
            # jezeli klucz nie ma wartosci albo ma wartosc pusta to jest zamieniany na nil
            :body =>"k0:\nk1: \t\t \nk2: \r\t\t\n",
            :expected =>{'k0'=>nil, 'k1'=>nil, 'k2'=>nil},
        },{
            :body =>" status: ERROR\r\nerror_nr: 100\r\nerror_message: NumberFormatException For input string: \"pos1\"",
            :expected =>{'status'=>'ERROR', 'error_nr'=>'100', 'error_message'=>'NumberFormatException For input string: "pos1"'},
        },{
            :body =>" status: ERROR\r\nerror_nr: 100\r\nerror_message: NumberFormatException For input string: \"pos1\"",
            :allowed=>['status'],
            :expected =>{'status'=>'ERROR'}
        }
        ].each_with_index do |data, index|
            result = connector.parse_body(data[:body], data[:allowed])
            assert_equal data[:expected], result, "Sample nr #{index}"
        end
    end

    # test komunikacji ale bez nawiązywania prawdziwego polaczenia - chodzi o sprawdzenie
    # zchowania w przypadku roznych parametrow
    def test_get_state_options_contract
        config = OrderedOptions.new
        config.key1='test-key1'
        config.key2='test-key1'
        config.pos_id=['pos-id', 'POS2']

        connector = TransactionSupport::PlatnosciPl::Connector.new(config)
        stub=flexstub(connector).should_receive(:init_http).once.and_return do
            flexmock('http') do |mock|
                mock.should_receive(:start).once.with(Proc)
            end
        end

        # wyjatki zwiazane z niedopuszczlnymi parametrami
        assert_raise_message('Transaction session parameter is empty'){connector.get_state(nil)}

        # hash jako parametr wiec oczekiwane jest ze bedize wypelniony poprawnymi parametrami
        assert_raise_message("There is no value for key='pos_id'"){connector.get_state({})}
        assert_raise_message("There is no value for key='pos_id'"){connector.get_state({:key=>'value'})}

        # parametry prawie poprawne - nie zgadza sie pos_id bo jest inne niz w konfiguracji
        pos_id = 'YouDontKnowMe'
        session_id = '123123'
        ts = 'timestamp'
        key = config.key2
        # to czy klucze sa stringami czy symbolami nie powinno miec znaczenia
        params = HashWithIndifferentAccess.new({
            'pos_id'=>pos_id,
            :session_id=>session_id,
            :ts=>ts,
            'sig'=>Digest::MD5.hexdigest("#{pos_id}#{session_id}#{ts}#{key}")
        })

        assert_raise_message("Given pos_id='YouDontKnowMe' is not valid"){connector.get_state(params)}

        # teraz powinno byc juz okej
        pos_id = 'POS2'
        session_id = '123123'
        ts = 'timestamp'
        key = config.key2
        # to czy klucze sa stringami czy symbolami nie powinno miec znaczenia
        params = HashWithIndifferentAccess.new({
            'pos_id'=>pos_id,
            :session_id=>session_id,
            :ts=>ts,
            'sig'=>Digest::MD5.hexdigest("#{pos_id}#{session_id}#{ts}#{key}")
        })
        connector.get_state(params)
    end

    # sprawdzenie metody niskopoziomowej przygotowywujace dane do wyslania jako
    # parametry Payment/get w  platnosci.pl
    def test_prepare_request_data
        config = OrderedOptions.new
        config.key1='test-key1'
        config.key2='test-key1'
        config.pos_id=['pos-id', 'POS2']
        connector = PlatnosciPl::Connector.new(config)
        # zmiana widocznosci metody na publiczna
        class<< connector
            public :prepare_request_data
        end
        data = connector.prepare_request_data('no-exists',nil)
        assert_equal 'no-exists', data[:session_id]
        assert_equal 'pos-id', data[:pos_id]

        data = connector.prepare_request_data('no-exists2','POS2')
        assert_equal 'no-exists2', data[:session_id]
        assert_equal 'POS2', data[:pos_id]
    end

    protected
    def assert_raise_message(message, exception_type=TransactionSupport::TransactionSupportError, &block)
        begin
            block.call
            flunk
        rescue => e
            assert_kind_of exception_type, e, "Expected type #{exception_type} but was #{e.class}"
            assert e.message.include?(message), "Expected msg: [#{message}] but was [#{e.message}]"
        end
    end
end
