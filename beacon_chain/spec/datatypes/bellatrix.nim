{.push raises: [].}
{.experimental: "notnil".}

import
  std/typetraits,
  stew/byteutils,
  json_serialization,
  ssz_serialization/types as sszTypes,
  ../digest,
  "."/[base, phase0, altair]

export json_serialization, base

const
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/paris.md#request-1
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/shanghai.md#request-1
  FORKCHOICEUPDATED_TIMEOUT* = 8.seconds

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/paris.md#request
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/shanghai.md#request
  NEWPAYLOAD_TIMEOUT* = 8.seconds

type
  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/beacon-chain.md#custom-types
  Transaction* = List[byte, Limit MAX_BYTES_PER_TRANSACTION]

  ExecutionAddress* = object
    data*: array[20, byte]  # TODO there's a network_metadata type, but the import hierarchy's inconvenient

  BloomLogs* = object
    data*: array[BYTES_PER_LOGS_BLOOM, byte]

  PayloadID* = array[8, byte]

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/beacon-chain.md#executionpayload
  ExecutionPayload* = object
    # Execution block header fields
    parent_hash*: Eth2Digest
    fee_recipient*: ExecutionAddress
      ## 'beneficiary' in the yellow paper
    state_root*: Eth2Digest
    receipts_root*: Eth2Digest
    logs_bloom*: BloomLogs
    prev_randao*: Eth2Digest
      ## 'difficulty' in the yellow paper
    block_number*: uint64
      ## 'number' in the yellow paper
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    extra_data*: List[byte, MAX_EXTRA_DATA_BYTES]
    base_fee_per_gas*: UInt256

    # Extra payload fields
    block_hash*: Eth2Digest
      ## Hash of execution block
    transactions*: List[Transaction, MAX_TRANSACTIONS_PER_PAYLOAD]

  ExecutionPayloadForSigning* = object
    executionPayload*: ExecutionPayload
    blockValue*: Wei

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/beacon-chain.md#executionpayloadheader
  ExecutionPayloadHeader* = object
    # Execution block header fields
    parent_hash*: Eth2Digest
    fee_recipient*: ExecutionAddress
    state_root*: Eth2Digest
    receipts_root*: Eth2Digest
    logs_bloom*: BloomLogs
    prev_randao*: Eth2Digest
    block_number*: uint64
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    extra_data*: List[byte, MAX_EXTRA_DATA_BYTES]
    base_fee_per_gas*: UInt256

    # Extra payload fields
    block_hash*: Eth2Digest
      ## Hash of execution block
    transactions_root*: Eth2Digest

  ExecutePayload* = proc(
    execution_payload: ExecutionPayload): bool {.gcsafe, raises: [].}

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/fork-choice.md#powblock
  PowBlock* = object
    block_hash*: Eth2Digest
    parent_hash*: Eth2Digest
    total_difficulty*: Eth2Digest   # uint256

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/beacon-chain.md#beaconstate
  BeaconState* = object
    # Versioning
    genesis_time*: uint64
    genesis_validators_root*: Eth2Digest
    slot*: Slot
    fork*: Fork

    # History
    latest_block_header*: BeaconBlockHeader
      ## `latest_block_header.state_root == ZERO_HASH` temporarily

    block_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
      ## Needed to process attestations, older to newer

    state_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    historical_roots*: HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]

    # Eth1
    eth1_data*: Eth1Data
    eth1_data_votes*:
      HashList[Eth1Data, Limit(EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH)]
    eth1_deposit_index*: uint64

    # Registry
    validators*: HashList[Validator, Limit VALIDATOR_REGISTRY_LIMIT]
    balances*: HashList[Gwei, Limit VALIDATOR_REGISTRY_LIMIT]

    # Randomness
    randao_mixes*: HashArray[Limit EPOCHS_PER_HISTORICAL_VECTOR, Eth2Digest]

    # Slashings
    slashings*: HashArray[Limit EPOCHS_PER_SLASHINGS_VECTOR, Gwei]
      ## Per-epoch sums of slashed effective balances

    # Participation
    previous_epoch_participation*: EpochParticipationFlags
    current_epoch_participation*: EpochParticipationFlags

    # Finality
    justification_bits*: JustificationBits
      ## Bit set for every recent justified epoch

    previous_justified_checkpoint*: Checkpoint
    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint

    # Inactivity
    inactivity_scores*: InactivityScores

    # Light client sync committees
    current_sync_committee*: SyncCommittee
    next_sync_committee*: SyncCommittee

    # Execution
    latest_execution_payload_header*: ExecutionPayloadHeader  # [New in Bellatrix]

  # TODO Careful, not nil analysis is broken / incomplete and the semantics will
  #      likely change in future versions of the language:
  #      https://github.com/nim-lang/RFCs/issues/250
  BeaconStateRef* = ref BeaconState not nil
  NilableBeaconStateRef* = ref BeaconState

  # TODO: There should be only a single generic HashedBeaconState definition
  HashedBeaconState* = object
    data*: BeaconState
    root*: Eth2Digest # hash_tree_root(data)

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/specs/phase0/beacon-chain.md#beaconblock
  BeaconBlock* = object
    ## For each slot, a proposer is chosen from the validator pool to propose
    ## a new block. Once the block as been proposed, it is transmitted to
    ## validators that will have a chance to vote on it through attestations.
    ## Each block collects attestations, or votes, on past blocks, thus a chain
    ## is formed.

    slot*: Slot
    proposer_index*: uint64 # `ValidatorIndex` after validation

    parent_root*: Eth2Digest
      ## Root hash of the previous block

    state_root*: Eth2Digest
      ## The state root, _after_ this block has been processed

    body*: BeaconBlockBody

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/bellatrix/beacon-chain.md#beaconblockbody
  BeaconBlockBody* = object
    randao_reveal*: ValidatorSig
    eth1_data*: Eth1Data
      ## Eth1 data vote

    graffiti*: GraffitiBytes
      ## Arbitrary data

    # Operations
    proposer_slashings*: List[ProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*: List[AttesterSlashing, Limit MAX_ATTESTER_SLASHINGS]
    attestations*: List[Attestation, Limit MAX_ATTESTATIONS]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[SignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    # [New in Altair]
    sync_aggregate*: SyncAggregate

    # Execution
    execution_payload*: ExecutionPayload  # [New in Bellatrix]

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/beacon-chain.md#signedbeaconblock
  SignedBeaconBlock* = object
    message*: BeaconBlock
    signature*: ValidatorSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  SomeSignedBeaconBlock* = SignedBeaconBlock
  SomeBeaconBlock* = BeaconBlock
  SomeBeaconBlockBody* = BeaconBlockBody

# TODO: There should be only a single generic HashedBeaconState definition
func initHashedBeaconState*(s: BeaconState): HashedBeaconState =
  HashedBeaconState(data: s)

func fromHex*(T: typedesc[BloomLogs], s: string): T {.
     raises: [ValueError].} =
  hexToByteArray(s, result.data)

func fromHex*(T: typedesc[ExecutionAddress], s: string): T {.
     raises: [ValueError].} =
  hexToByteArray(s, result.data)

proc writeValue*(
    writer: var JsonWriter, value: ExecutionAddress) {.raises: [IOError].} =
  writer.writeValue to0xHex(value.data)

proc readValue*(reader: var JsonReader, value: var ExecutionAddress) {.
     raises: [IOError, SerializationError].} =
  try:
    hexToByteArray(reader.readValue(string), value.data)
  except ValueError:
    raiseUnexpectedValue(reader,
                         "ExecutionAddress value should be a valid hex string")

func `$`*(v: ExecutionAddress): string =
  v.data.toHex()

func shortLog*(v: SomeBeaconBlock): auto =
  (
    slot: shortLog(v.slot),
    proposer_index: v.proposer_index,
    parent_root: shortLog(v.parent_root),
    state_root: shortLog(v.state_root),
    eth1data: v.body.eth1_data,
    graffiti: $v.body.graffiti,
    proposer_slashings_len: v.body.proposer_slashings.len(),
    attester_slashings_len: v.body.attester_slashings.len(),
    attestations_len: v.body.attestations.len(),
    deposits_len: v.body.deposits.len(),
    voluntary_exits_len: v.body.voluntary_exits.len(),
    sync_committee_participants: v.body.sync_aggregate.num_active_participants,
    block_number: v.body.execution_payload.block_number,
    # TODO checksum hex? shortlog?
    block_hash: to0xHex(v.body.execution_payload.block_hash.data),
    parent_hash: to0xHex(v.body.execution_payload.parent_hash.data),
    fee_recipient: to0xHex(v.body.execution_payload.fee_recipient.data),
    bls_to_execution_changes_len: 0,  # Capella compat
    blob_kzg_commitments_len: 0,  # Deneb compat
  )

func shortLog*(v: SomeSignedBeaconBlock): auto =
  (
    blck: shortLog(v.message),
    signature: shortLog(v.signature)
  )

func shortLog*(v: ExecutionPayload): auto =
  (
    parent_hash: shortLog(v.parent_hash),
    fee_recipient: $v.fee_recipient,
    state_root: shortLog(v.state_root),
    receipts_root: shortLog(v.receipts_root),
    prev_randao: shortLog(v.prev_randao),
    block_number: v.block_number,
    gas_limit: v.gas_limit,
    gas_used: v.gas_used,
    timestamp: v.timestamp,
    extra_data: "",
    base_fee_per_gas: $(v.base_fee_per_gas),
    block_hash: shortLog(v.block_hash),
    num_transactions: len(v.transactions)
  )
