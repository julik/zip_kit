# frozen_string_literal: true

require_relative "../../spec_helper"

describe ZipKit::Streamer::StateMachine do
  subject { described_class.new }

  describe "initial state" do
    it "starts in INITIAL state" do
      expect(subject.state).to eq(:initial)
      expect(subject.can_begin_entry?).to be true
      expect(subject.can_close_archive?).to be true
      expect(subject.closed?).to be false
      expect(subject.in_entry?).to be false
    end

    it "has nil previous_state" do
      expect(subject.previous_state).to be_nil
    end

    it "has zero transition_offset" do
      expect(subject.transition_offset).to eq(0)
    end
  end

  describe "#begin_entry" do
    it "transitions to LOCAL_HEADER state" do
      entry = double("Entry", filename: "test.txt")
      subject.begin_entry(entry, 0)

      expect(subject.state).to eq(:local_header)
      expect(subject.previous_state).to eq(:initial)
      expect(subject.entry_offset).to eq(0)
      expect(subject.current_entry).to eq(entry)
      expect(subject.in_entry?).to be true
    end
  end

  describe "#begin_entry_body" do
    it "transitions from LOCAL_HEADER to ENTRY_BODY" do
      subject.begin_entry(double("Entry"), 0)
      subject.begin_entry_body(50)

      expect(subject.state).to eq(:entry_body)
      expect(subject.previous_state).to eq(:local_header)
      expect(subject.transition_offset).to eq(50)
      expect(subject.can_write_body?).to be true
    end
  end

  describe "full entry lifecycle with data descriptor" do
    it "follows the complete lifecycle" do
      entry = double("Entry", filename: "test.txt")

      subject.begin_entry(entry, 0)
      expect(subject.state).to eq(:local_header)
      expect(subject.entry_offset).to eq(0)

      subject.begin_entry_body(50)
      expect(subject.state).to eq(:entry_body)
      expect(subject.can_write_body?).to be true

      subject.write_data_descriptor(150)
      expect(subject.state).to eq(:data_descriptors)
      expect(subject.entry_offset).to be_nil
      expect(subject.current_entry).to be_nil
      expect(subject.can_begin_entry?).to be true
    end
  end

  describe "invalid transitions" do
    it "prevents LOCAL_HEADER -> LOCAL_HEADER" do
      subject.begin_entry(double("Entry"), 0)

      expect { subject.begin_entry(double("Entry2"), 100) }
        .to raise_error(ZipKit::Streamer::InvalidState, /Cannot transition/)
    end

    it "prevents INITIAL -> ENTRY_BODY" do
      expect { subject.begin_entry_body(0) }
        .to raise_error(ZipKit::Streamer::InvalidState, /Cannot transition/)
    end

    it "prevents INITIAL -> DATA_DESCRIPTORS" do
      expect { subject.write_data_descriptor(0) }
        .to raise_error(ZipKit::Streamer::InvalidState, /Cannot transition/)
    end

    it "prevents LOCAL_HEADER -> CENTRAL_DIRECTORY" do
      subject.begin_entry(double("Entry"), 0)

      expect { subject.begin_central_directory(50) }
        .to raise_error(ZipKit::Streamer::InvalidState, /Cannot transition/)
    end
  end

  describe "entries without data descriptors" do
    it "allows ENTRY_BODY -> LOCAL_HEADER" do
      subject.begin_entry(double("Entry1"), 0)
      subject.begin_entry_body(50)

      # Direct transition to next entry (no data descriptor)
      subject.begin_entry(double("Entry2"), 100)
      expect(subject.state).to eq(:local_header)
    end

    it "allows ENTRY_BODY -> CENTRAL_DIRECTORY" do
      subject.begin_entry(double("Entry1"), 0)
      subject.begin_entry_body(50)

      subject.begin_central_directory(100)
      expect(subject.state).to eq(:central_directory)
    end
  end

  describe "DATA_DESCRIPTORS transitions" do
    before do
      subject.begin_entry(double("Entry1"), 0)
      subject.begin_entry_body(50)
      subject.write_data_descriptor(150)
    end

    it "allows DATA_DESCRIPTORS -> LOCAL_HEADER" do
      subject.begin_entry(double("Entry2"), 150)
      expect(subject.state).to eq(:local_header)
    end

    it "allows DATA_DESCRIPTORS -> CENTRAL_DIRECTORY" do
      subject.begin_central_directory(150)
      expect(subject.state).to eq(:central_directory)
    end
  end

  describe "#rollback" do
    it "raises when called from INITIAL" do
      expect { subject.rollback(100) }
        .to raise_error(ZipKit::Streamer::InvalidState, /only valid during entry writing/)
    end

    it "raises when called from DATA_DESCRIPTORS" do
      subject.begin_entry(double("Entry"), 0)
      subject.begin_entry_body(50)
      subject.write_data_descriptor(150)

      expect { subject.rollback(200) }
        .to raise_error(ZipKit::Streamer::InvalidState, /only valid during entry writing/)
    end

    it "returns context and transitions to ENTRY_BODY from ENTRY_BODY" do
      entry = double("Entry", filename: "fail.txt")
      subject.begin_entry(entry, 42)
      subject.begin_entry_body(100)

      context = subject.rollback(250)

      expect(context[:entry_offset]).to eq(42)
      expect(context[:current_entry]).to eq(entry)
      expect(context[:bytes_written]).to eq(208) # 250 - 42

      # Transitions to entry_body (allows next entry or close)
      expect(subject.state).to eq(:entry_body)
      expect(subject.entry_offset).to be_nil
      expect(subject.current_entry).to be_nil
    end

    it "returns context and transitions to ENTRY_BODY from LOCAL_HEADER" do
      entry = double("Entry", filename: "fail.txt")
      subject.begin_entry(entry, 42)
      # Don't call begin_entry_body - simulates failure during header write

      context = subject.rollback(60)

      expect(context[:entry_offset]).to eq(42)
      expect(context[:current_entry]).to eq(entry)
      expect(context[:bytes_written]).to eq(18) # 60 - 42

      # Transitions to entry_body (allows next entry or close)
      expect(subject.state).to eq(:entry_body)
      expect(subject.entry_offset).to be_nil
      expect(subject.current_entry).to be_nil
    end

    it "allows beginning a new entry after rollback from ENTRY_BODY" do
      subject.begin_entry(double("Entry1"), 0)
      subject.begin_entry_body(50)
      subject.rollback(100)

      # Should be able to start a new entry
      subject.begin_entry(double("Entry2"), 100)
      expect(subject.state).to eq(:local_header)
    end

    it "allows beginning a new entry after rollback from LOCAL_HEADER" do
      subject.begin_entry(double("Entry1"), 0)
      subject.rollback(50)

      # Should be able to start a new entry
      subject.begin_entry(double("Entry2"), 50)
      expect(subject.state).to eq(:local_header)
    end

    it "allows closing archive after rollback" do
      subject.begin_entry(double("Entry1"), 0)
      subject.begin_entry_body(50)
      subject.rollback(100)

      # Should be able to close archive
      subject.begin_central_directory(100)
      expect(subject.state).to eq(:central_directory)
    end
  end

  describe "#finalize" do
    it "transitions from CENTRAL_DIRECTORY to END_OF_CENTRAL_DIRECTORY" do
      subject.begin_central_directory(0)
      subject.finalize(100)

      expect(subject.state).to eq(:end_of_central_directory)
      expect(subject.closed?).to be true
    end
  end

  describe "empty archive" do
    it "allows INITIAL -> CENTRAL_DIRECTORY (empty archive)" do
      subject.begin_central_directory(0)
      expect(subject.state).to eq(:central_directory)
    end
  end

  describe "query methods" do
    describe "#can_begin_entry?" do
      it "returns true from states that allow new entries" do
        expect(subject.can_begin_entry?).to be true

        subject.begin_entry(double("Entry"), 0)
        subject.begin_entry_body(50)
        expect(subject.can_begin_entry?).to be true

        subject.write_data_descriptor(100)
        expect(subject.can_begin_entry?).to be true
      end

      it "returns false from LOCAL_HEADER" do
        subject.begin_entry(double("Entry"), 0)
        expect(subject.can_begin_entry?).to be false
      end

      it "returns false from CENTRAL_DIRECTORY" do
        subject.begin_central_directory(0)
        expect(subject.can_begin_entry?).to be false
      end

      it "returns false when closed" do
        subject.begin_central_directory(0)
        subject.finalize(100)
        expect(subject.can_begin_entry?).to be false
      end
    end

    describe "#can_write_body?" do
      it "returns true only from ENTRY_BODY" do
        expect(subject.can_write_body?).to be false

        subject.begin_entry(double("Entry"), 0)
        expect(subject.can_write_body?).to be false

        subject.begin_entry_body(50)
        expect(subject.can_write_body?).to be true

        subject.write_data_descriptor(100)
        expect(subject.can_write_body?).to be false
      end
    end

    describe "#can_close_archive?" do
      it "returns true from states that allow closing" do
        expect(subject.can_close_archive?).to be true

        subject.begin_entry(double("Entry"), 0)
        subject.begin_entry_body(50)
        expect(subject.can_close_archive?).to be true

        subject.write_data_descriptor(100)
        expect(subject.can_close_archive?).to be true
      end

      it "returns false from LOCAL_HEADER" do
        subject.begin_entry(double("Entry"), 0)
        expect(subject.can_close_archive?).to be false
      end

      it "returns false from CENTRAL_DIRECTORY" do
        subject.begin_central_directory(0)
        expect(subject.can_close_archive?).to be false
      end
    end

    describe "#closed?" do
      it "returns true only after finalize" do
        expect(subject.closed?).to be false

        subject.begin_central_directory(0)
        expect(subject.closed?).to be false

        subject.finalize(100)
        expect(subject.closed?).to be true
      end
    end

    describe "#in_entry?" do
      it "returns true from LOCAL_HEADER and ENTRY_BODY" do
        expect(subject.in_entry?).to be false

        subject.begin_entry(double("Entry"), 0)
        expect(subject.in_entry?).to be true

        subject.begin_entry_body(50)
        expect(subject.in_entry?).to be true

        subject.write_data_descriptor(100)
        expect(subject.in_entry?).to be false
      end
    end
  end
end
