# frozen_string_literal: true

# Tracks the state of ZIP output to enforce valid call sequences.
# States mirror the ZIP file structure: local headers, entry bodies,
# data descriptors, central directory, and EOCD.
class ZipKit::Streamer::StateMachine
  INITIAL = :initial
  LOCAL_HEADER = :local_header
  ENTRY_BODY = :entry_body
  DATA_DESCRIPTORS = :data_descriptors
  CENTRAL_DIRECTORY = :central_directory
  END_OF_CENTRAL_DIRECTORY = :end_of_central_directory

  TRANSITIONS = {
    INITIAL => [LOCAL_HEADER, CENTRAL_DIRECTORY],
    LOCAL_HEADER => [ENTRY_BODY],
    ENTRY_BODY => [DATA_DESCRIPTORS, LOCAL_HEADER, CENTRAL_DIRECTORY],
    DATA_DESCRIPTORS => [LOCAL_HEADER, CENTRAL_DIRECTORY],
    CENTRAL_DIRECTORY => [END_OF_CENTRAL_DIRECTORY],
    END_OF_CENTRAL_DIRECTORY => []
  }.freeze

  attr_reader :state, :previous_state, :transition_offset
  attr_reader :entry_offset, :current_entry

  def initialize
    @state = INITIAL
    @previous_state = nil
    @transition_offset = 0
    @entry_offset = nil
    @current_entry = nil
  end

  def transition!(to_state, offset)
    unless TRANSITIONS[@state]&.include?(to_state)
      raise ZipKit::Streamer::InvalidState,
        "Cannot transition from #{@state} to #{to_state}. " \
        "Valid next states: #{TRANSITIONS[@state].inspect}"
    end

    @previous_state = @state
    @transition_offset = offset
    @state = to_state
  end

  def begin_entry(entry, offset)
    transition!(LOCAL_HEADER, offset)
    @entry_offset = offset
    @current_entry = entry
  end

  def begin_entry_body(offset)
    transition!(ENTRY_BODY, offset)
  end

  def write_data_descriptor(offset)
    transition!(DATA_DESCRIPTORS, offset)
    @entry_offset = nil
    @current_entry = nil
  end

  def begin_central_directory(offset)
    transition!(CENTRAL_DIRECTORY, offset)
    @entry_offset = nil
    @current_entry = nil
  end

  def finalize(offset)
    transition!(END_OF_CENTRAL_DIRECTORY, offset)
  end

  def rollback(current_offset)
    unless @state == ENTRY_BODY || @state == LOCAL_HEADER
      raise ZipKit::Streamer::InvalidState,
        "Cannot rollback from #{@state}. Rollback is only valid during entry writing."
    end

    context = {
      entry_offset: @entry_offset,
      current_entry: @current_entry,
      bytes_written: current_offset - @entry_offset
    }

    # Clear entry tracking, and transition to ENTRY_BODY
    # (this allows starting new entries or closing the archive)
    @previous_state = @state
    @state = ENTRY_BODY
    @transition_offset = current_offset
    @entry_offset = nil
    @current_entry = nil

    context
  end

  # Query methods
  def can_begin_entry?
    TRANSITIONS[@state]&.include?(LOCAL_HEADER)
  end

  def can_write_body?
    @state == ENTRY_BODY
  end

  def can_close_archive?
    TRANSITIONS[@state]&.include?(CENTRAL_DIRECTORY)
  end

  def closed?
    @state == END_OF_CENTRAL_DIRECTORY
  end

  def in_entry?
    @state == LOCAL_HEADER || @state == ENTRY_BODY
  end
end
