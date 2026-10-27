module HTTP2
  # Identifiers of the settings parameters defined in RFC 9113 section 6.5.2.
  enum SettingIdentifier : UInt16
    HEADER_TABLE_SIZE      = 0x1
    ENABLE_PUSH            = 0x2
    MAX_CONCURRENT_STREAMS = 0x3
    INITIAL_WINDOW_SIZE    = 0x4
    MAX_FRAME_SIZE         = 0x5
    MAX_HEADER_LIST_SIZE   = 0x6
  end

  # The set of settings advertised by one endpoint.
  struct Settings
    DEFAULT_HEADER_TABLE_SIZE   =   4096_u32
    DEFAULT_INITIAL_WINDOW_SIZE = 65_535_u32

    property header_table_size : UInt32 = DEFAULT_HEADER_TABLE_SIZE
    property? enable_push : Bool = true
    property max_concurrent_streams : UInt32? = nil
    property initial_window_size : UInt32 = DEFAULT_INITIAL_WINDOW_SIZE
    property max_frame_size : UInt32 = DEFAULT_MAX_FRAME_SIZE.to_u32
    property max_header_list_size : UInt32? = nil

    def initialize(@header_table_size = DEFAULT_HEADER_TABLE_SIZE, @enable_push = true,
                   @max_concurrent_streams = nil, @initial_window_size = DEFAULT_INITIAL_WINDOW_SIZE,
                   @max_frame_size = DEFAULT_MAX_FRAME_SIZE.to_u32, @max_header_list_size = nil)
    end

    # Validates a single setting value as received from a peer and raises the
    # appropriate `ConnectionError` if it is invalid.
    def self.validate(id : UInt16, value : UInt32) : Nil
      case SettingIdentifier.from_value?(id)
      when SettingIdentifier::ENABLE_PUSH
        unless value <= 1
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid SETTINGS_ENABLE_PUSH value #{value}")
        end
      when SettingIdentifier::INITIAL_WINDOW_SIZE
        if value > MAX_WINDOW_SIZE
          raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "SETTINGS_INITIAL_WINDOW_SIZE #{value} too large")
        end
      when SettingIdentifier::MAX_FRAME_SIZE
        unless DEFAULT_MAX_FRAME_SIZE <= value <= MAX_ALLOWED_FRAME_SIZE
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid SETTINGS_MAX_FRAME_SIZE #{value}")
        end
      end
    end

    # Applies a (validated) setting. Unknown settings are ignored.
    def apply(id : UInt16, value : UInt32) : Nil
      case SettingIdentifier.from_value?(id)
      when SettingIdentifier::HEADER_TABLE_SIZE      then @header_table_size = value
      when SettingIdentifier::ENABLE_PUSH            then @enable_push = value == 1
      when SettingIdentifier::MAX_CONCURRENT_STREAMS then @max_concurrent_streams = value
      when SettingIdentifier::INITIAL_WINDOW_SIZE    then @initial_window_size = value
      when SettingIdentifier::MAX_FRAME_SIZE         then @max_frame_size = value
      when SettingIdentifier::MAX_HEADER_LIST_SIZE   then @max_header_list_size = value
      end
    end

    # Returns the parameters that differ from the protocol defaults, suitable
    # for sending in a SETTINGS frame.
    def to_parameters : Array({UInt16, UInt32})
      params = [] of {UInt16, UInt32}
      params << {SettingIdentifier::HEADER_TABLE_SIZE.value, header_table_size} if header_table_size != DEFAULT_HEADER_TABLE_SIZE
      params << {SettingIdentifier::ENABLE_PUSH.value, 0_u32} unless enable_push?
      if max = max_concurrent_streams
        params << {SettingIdentifier::MAX_CONCURRENT_STREAMS.value, max}
      end
      params << {SettingIdentifier::INITIAL_WINDOW_SIZE.value, initial_window_size} if initial_window_size != DEFAULT_INITIAL_WINDOW_SIZE
      params << {SettingIdentifier::MAX_FRAME_SIZE.value, max_frame_size} if max_frame_size != DEFAULT_MAX_FRAME_SIZE
      if max = max_header_list_size
        params << {SettingIdentifier::MAX_HEADER_LIST_SIZE.value, max}
      end
      params
    end
  end
end
