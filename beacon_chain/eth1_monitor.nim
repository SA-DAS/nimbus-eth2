import
  std/[deques, tables, hashes, options, strformat, strutils],
  chronos, web3, web3/ethtypes as web3Types, json, chronicles/timings,
  eth/common/eth_types, eth/async_utils,
  spec/[datatypes, digest, crypto, beaconstate, helpers],
  ssz, beacon_chain_db, network_metadata, merkle_minimal, beacon_node_status

export
  web3Types

logScope:
  topics = "eth1"

contract(DepositContract):
  proc deposit(pubkey: Bytes48,
               withdrawalCredentials: Bytes32,
               signature: Bytes96,
               deposit_data_root: FixedBytes[32])

  proc get_deposit_root(): FixedBytes[32]
  proc get_deposit_count(): Bytes8

  proc DepositEvent(pubkey: Bytes48,
                    withdrawalCredentials: Bytes32,
                    amount: Bytes8,
                    signature: Bytes96,
                    index: Bytes8) {.event.}
# TODO
# The raises list of this module are still not usable due to general
# Exceptions being reported from Chronos's asyncfutures2.

type
  Eth1BlockNumber* = uint64
  Eth1BlockTimestamp* = uint64
  Eth1BlockHeader = web3Types.BlockHeader

  Database* = object

  Eth1Block* = ref object
    number*: Eth1BlockNumber
    timestamp*: Eth1BlockTimestamp
    deposits*: seq[Deposit]
    voteData*: Eth1Data
    activeValidatorsCount*: uint64

  Eth1Chain* = object
    knownStart: Eth1Data
    blocks: Deque[Eth1Block]
    blocksByHash: Table[BlockHash, Eth1Block]

  Eth1Monitor* = ref object
    db: BeaconChainDB
    preset: RuntimePreset
    depositContractDeployedAt: BlockHashOrNumber

    dataProvider: Web3DataProviderRef

    latestEth1BlockNumber: Eth1BlockNumber
    eth1Progress: AsyncEvent

    eth1Chain: Eth1Chain

    genesisState: NilableBeaconStateRef
    genesisStateFut: Future[void]

    runFut: Future[void]

  Web3DataProvider* = object
    url: string
    web3: Web3
    ns: Sender[DepositContract]
    blockHeadersSubscription: Subscription

  Web3DataProviderRef* = ref Web3DataProvider

  CorruptDataProvider = object of CatchableError

  DisconnectHandler* = proc () {.gcsafe, raises: [Defect].}

  DepositEventHandler* = proc (
    pubkey: Bytes48,
    withdrawalCredentials: Bytes32,
    amount: Bytes8,
    signature: Bytes96, merkleTreeIndex: Bytes8, j: JsonNode) {.raises: [Defect], gcsafe.}

  BlockProposalEth1Data* = object
    vote*: Eth1Data
    deposits*: seq[Deposit]

const
  web3Timeouts = 5.seconds
  hasDepositRootChecks = true # defined(with_deposit_root_checks)

template depositContractAddress(m: Eth1Monitor): Eth1Address =
  m.dataProvider.ns.contractAddress

template web3Url(m: Eth1Monitor): string =
  m.dataProvider.url

template blocks*(m: Eth1Monitor): Deque[Eth1Block] =
  m.eth1Chain.blocks

proc fixupWeb3Urls*(web3Url: var string) =
  ## Converts HTTP and HTTPS Infura URLs to their WebSocket equivalents
  ## because we are missing a functional HTTPS client.
  let normalizedUrl = toLowerAscii(web3Url)
  var pos = 0

  template skip(x: string): bool {.dirty.} =
    if normalizedUrl.len - pos >= x.len and
       normalizedUrl.toOpenArray(pos, pos + x.len - 1) == x:
      pos += x.len
      true
    else:
      false

  if not (skip("https://") or skip("http://")):
    if not (skip("ws://") or skip("wss://")):
      web3Url = "ws://" & web3Url
      warn "The Web3 URL does not specify a protocol. Assuming a WebSocket server", web3Url
    return

  block infuraRewrite:
    var pos = pos
    let network = if skip("mainnet"): mainnet
                  elif skip("goerli"): goerli
                  else: break

    if not skip(".infura.io/v3/"):
      break

    template infuraKey: string = normalizedUrl.substr(pos)

    web3Url = "wss://" & $network & ".infura.io/ws/v3/" & infuraKey
    return

  block gethRewrite:
    web3Url = "ws://" & normalizedUrl.substr(pos)
    warn "Only WebSocket web3 providers are supported. Rewriting URL", web3Url

# TODO: Add preset validation
# MIN_GENESIS_ACTIVE_VALIDATOR_COUNT should be larger than SLOTS_PER_EPOCH
#  doAssert SECONDS_PER_ETH1_BLOCK * preset.ETH1_FOLLOW_DISTANCE < GENESIS_DELAY,
#             "Invalid configuration: GENESIS_DELAY is set too low"

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#get_eth1_data
func compute_time_at_slot(state: BeaconState, slot: Slot): uint64 =
  state.genesis_time + slot * SECONDS_PER_SLOT

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#get_eth1_data
func voting_period_start_time*(state: BeaconState): uint64 =
  let eth1_voting_period_start_slot =
    state.slot - state.slot mod SLOTS_PER_ETH1_VOTING_PERIOD.uint64
  compute_time_at_slot(state, eth1_voting_period_start_slot)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#get_eth1_data
func is_candidate_block(preset: RuntimePreset,
                        blk: Eth1Block,
                        period_start: uint64): bool =
  (blk.timestamp + SECONDS_PER_ETH1_BLOCK * preset.ETH1_FOLLOW_DISTANCE <= period_start) and
  (blk.timestamp + SECONDS_PER_ETH1_BLOCK * preset.ETH1_FOLLOW_DISTANCE * 2 >= period_start)

func asEth2Digest*(x: BlockHash): Eth2Digest =
  Eth2Digest(data: array[32, byte](x))

template asBlockHash(x: Eth2Digest): BlockHash =
  BlockHash(x.data)

func shortLog*(b: Eth1Block): string =
  &"{b.number}:{shortLog b.voteData.block_hash}"

template findBlock*(eth1Chain: Eth1Chain, hash: BlockHash): Eth1Block =
  eth1Chain.blocksByHash.getOrDefault(hash, nil)

template findBlock*(eth1Chain: Eth1Chain, eth1Data: Eth1Data): Eth1Block =
  getOrDefault(eth1Chain.blocksByHash, asBlockHash(eth1Data.block_hash), nil)

func makeSuccessorWithoutDeposits(existingBlock: Eth1Block,
                                  successor: BlockObject): ETh1Block =
  Eth1Block(
    number: Eth1BlockNumber successor.number,
    timestamp: Eth1BlockTimestamp successor.timestamp,
    voteData: Eth1Data(
      block_hash: successor.hash.asEth2Digest,
      deposit_count: existingBlock.voteData.deposit_count,
      deposit_root: existingBlock.voteData.deposit_root),
    activeValidatorsCount: existingBlock.activeValidatorsCount)

func latestCandidateBlock(m: Eth1Monitor, periodStart: uint64): Eth1Block =
  for i in countdown(m.eth1Chain.blocks.len - 1, 0):
    let blk = m.eth1Chain.blocks[i]
    if is_candidate_block(m.preset, blk, periodStart):
      return blk

func popFirst(eth1Chain: var Eth1Chain) =
  let removed = eth1Chain.blocks.popFirst
  eth1Chain.blocksByHash.del removed.voteData.block_hash.asBlockHash

func addBlock(eth1Chain: var Eth1Chain, newBlock: Eth1Block) =
  eth1Chain.blocks.addLast newBlock
  eth1Chain.blocksByHash[newBlock.voteData.block_hash.asBlockHash] = newBlock

func hash*(x: Eth1Data): Hash =
  hashData(unsafeAddr x, sizeof(x))

template hash*(x: Eth1Block): Hash =
  hash(x.voteData)

proc close*(p: Web3DataProviderRef): Future[void] {.async.} =
  if p.blockHeadersSubscription != nil:
    await p.blockHeadersSubscription.unsubscribe()

  await p.web3.close()

proc getBlockByHash*(p: Web3DataProviderRef, hash: BlockHash):
                     Future[BlockObject] =
  return p.web3.provider.eth_getBlockByHash(hash, false)

proc getBlockByNumber*(p: Web3DataProviderRef,
                       number: Eth1BlockNumber): Future[BlockObject] =
  return p.web3.provider.eth_getBlockByNumber(&"0x{number:X}", false)

template readJsonField(j: JsonNode, fieldName: string, ValueType: type): untyped =
  var res: ValueType
  fromJson(j[fieldName], fieldName, res)
  res

proc depositEventsToBlocks(depositsList: JsonNode): seq[Eth1Block] =
  if depositsList.kind != JArray:
    raise newException(CatchableError,
      "Web3 provider didn't return a list of deposit events")

  var lastEth1Block: Eth1Block

  for logEvent in depositsList:
    let
      blockNumber = Eth1BlockNumber readJsonField(logEvent, "blockNumber", Quantity)
      blockHash = readJsonField(logEvent, "blockHash", BlockHash)
      logData = strip0xPrefix(logEvent["data"].getStr)

    if lastEth1Block == nil or lastEth1Block.number != blockNumber:
      lastEth1Block = Eth1Block(
        number: blockNumber,
        voteData: Eth1Data(block_hash: blockHash.asEth2Digest))

      result.add lastEth1Block

    var
      pubkey: Bytes48
      withdrawalCredentials: Bytes32
      amount: Bytes8
      signature: Bytes96
      index: Bytes8

    var offset = 0
    offset += decode(logData, offset, pubkey)
    offset += decode(logData, offset, withdrawalCredentials)
    offset += decode(logData, offset, amount)
    offset += decode(logData, offset, signature)
    offset += decode(logData, offset, index)

    lastEth1Block.deposits.add Deposit(
      data: DepositData(
        pubkey: ValidatorPubKey.init(array[48, byte](pubkey)),
        withdrawal_credentials: Eth2Digest(data: array[32, byte](withdrawalCredentials)),
        amount: bytes_to_uint64(array[8, byte](amount)),
        signature: ValidatorSig.init(array[96, byte](signature))))

proc fetchTimestamp(p: Web3DataProviderRef, blk: Eth1Block) {.async.} =
  let web3block = await p.getBlockByHash(blk.voteData.block_hash.asBlockHash)
  blk.timestamp = Eth1BlockTimestamp web3block.timestamp

when hasDepositRootChecks:
  type
    DepositContractDataStatus = enum
      Fetched
      VerifiedCorrect
      DepositRootIncorrect
      DepositRootUnavailable
      DepositCountIncorrect
      DepositCountUnavailable

  proc fetchDepositContractData(p: Web3DataProviderRef, blk: Eth1Block):
                                Future[DepositContractDataStatus] {.async.} =
    let
      depositRoot = p.ns.get_deposit_root.call(blockNumber = blk.number)
      rawCount = p.ns.get_deposit_count.call(blockNumber = blk.number)

    try:
      let fetchedRoot = asEth2Digest(await depositRoot)
      if blk.voteData.deposit_root == default(Eth2Digest):
        blk.voteData.deposit_root = fetchedRoot
        result = Fetched
      elif blk.voteData.deposit_root == fetchedRoot:
        result = VerifiedCorrect
      else:
        result = DepositRootIncorrect
    except CatchableError as err:
      debug "Failed to fetch deposits root",
        blockNumber = blk.number,
        err = err.msg
      result = DepositRootUnavailable

    try:
      let fetchedCount = bytes_to_uint64(array[8, byte](await rawCount))
      if blk.voteData.deposit_count == 0:
        blk.voteData.deposit_count = fetchedCount
      elif blk.voteData.deposit_count != fetchedCount:
        result = DepositCountIncorrect
    except CatchableError as err:
      debug "Failed to fetch deposits count",
            blockNumber = blk.number,
            err = err.msg
      result = DepositCountUnavailable

proc onBlockHeaders*(p: Web3DataProviderRef,
                     blockHeaderHandler: BlockHeaderHandler,
                     errorHandler: SubscriptionErrorHandler) {.async.} =
  if p.blockHeadersSubscription != nil:
    await p.blockHeadersSubscription.unsubscribe()

  info "Waiting for new Eth1 block headers"

  p.blockHeadersSubscription = await p.web3.subscribeForBlockHeaders(
    blockHeaderHandler, errorHandler)

func getDepositsRoot(m: DepositsMerkleizer): Eth2Digest =
  mixInLength(m.getFinalHash, int m.totalChunks)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#get_eth1_data
proc getBlockProposalData*(m: Eth1Monitor,
                           state: BeaconState,
                           finalizedEth1Data: Eth1Data): BlockProposalEth1Data =
  var pendingDepositsCount = state.eth1_data.deposit_count -
                             state.eth1_deposit_index
  # TODO(zah)
  #      To make block proposal cheaper, we can perform this action more regularly
  #      (e.g. in BeaconNode.onSlot). But keep in mind that this action needs to be
  #      performed only when there are validators attached to the node.
  let ourDepositsCount = m.db.deposits.len
  let targetDepositsCount = finalizedEth1Data.deposit_count
  let hasLatestDeposits = if ourDepositsCount >= targetDepositsCount:
    m.db.finalizedEth2DepositsMerkleizer.advanceTo(m.db, targetDepositsCount)
    let ourDepositsRoot = m.db.finalizedEth2DepositsMerkleizer.getDepositsRoot

    if (ourDepositsRoot != finalizedEth1Data.deposit_root):
      error "Corrupted deposits history. Producing block without deposits",
            ourDepositsRoot,
            targetDepositsRoot = finalizedEth1Data.deposit_root,
            depositsCount = ourDepositsCount
      false
    else:
      true
  else:
    warn "ETH1 deposits not fully synced. Producing block without deposits",
         targetDepositsCount, ourDepositsCount
    false

  let periodStart = voting_period_start_time(state)

  var otherVotesCountTable = initCountTable[Eth1Data]()
  for vote in state.eth1_data_votes:
    let
      eth1Block = m.eth1Chain.findBlock(vote)
      isSuccessor = vote.deposit_count >= state.eth1_data.deposit_count
      # TODO(zah)
      # There is a slight deviation from the spec here to deal with the following
      # problem: the in-memory database of eth1 blocks for a restarted node will
      # be empty which will lead a "no change" vote. To fix this, we'll need to
      # add rolling persistance for all potentially voted on blocks.
      isCandidate = (eth1Block == nil or is_candidate_block(m.preset, eth1Block, periodStart))

    if isSuccessor and isCandidate:
      otherVotesCountTable.inc vote
    else:
      debug "Ignoring eth1 vote", root = vote.block_hash, isSuccessor, isCandidate

  if otherVotesCountTable.len > 0:
    let (winningVote, votes) = otherVotesCountTable.largest
    debug "Voting on eth1 head with majority", votes
    result.vote = winningVote
    if uint64((votes + 1) * 2) > SLOTS_PER_ETH1_VOTING_PERIOD:
      pendingDepositsCount = winningVote.deposit_count - state.eth1_deposit_index
  else:
    let latestBlock = m.latestCandidateBlock(periodStart)
    if latestBlock == nil:
      debug "No acceptable eth1 votes and no recent candidates. Voting no change"
      result.vote = state.eth1_data
    else:
      debug "No acceptable eth1 votes. Voting for latest candidate"
      result.vote = latestBlock.voteData

  if pendingDepositsCount > 0 and hasLatestDeposits:
    let totalDepositsInNewBlock = min(MAX_DEPOSITS, pendingDepositsCount)

    var
      deposits = newSeq[Deposit](pendingDepositsCount)
      depositRoots = newSeq[Eth2Digest](pendingDepositsCount)
      depositsMerkleizerClone = clone m.db.finalizedEth2DepositsMerkleizer

    depositsMerkleizerClone.advanceTo(m.db, state.eth1_deposit_index)

    for i in 0 ..< totalDepositsInNewBlock:
      deposits[i].data = m.db.deposits.get(state.eth1_deposit_index + i)
      depositRoots[i] = hash_tree_root(deposits[i].data)

    let proofs = depositsMerkleizerClone.addChunksAndGenMerkleProofs(depositRoots)

    for i in 0 ..< totalDepositsInNewBlock:
      deposits[i].proof[0..31] = proofs.getProof(i.int)
      deposits[i].proof[32].data[0..7] =
        toBytesLE uint64(state.eth1_deposit_index + i + 1)

    swap(result.deposits, deposits)

proc new(T: type Web3DataProvider,
         depositContractAddress: Eth1Address,
         web3Url: string): Future[Result[Web3DataProviderRef, string]] {.async.} =
  let web3Fut = newWeb3(web3Url)
  yield web3Fut or sleepAsync(chronos.seconds(5))
  if (not web3Fut.finished) or web3Fut.failed:
    await cancelAndWait(web3Fut)
    return err "Failed to setup web3 connection"

  let
    web3 = web3Fut.read
    ns = web3.contractSender(DepositContract, depositContractAddress)

  return ok Web3DataProviderRef(url: web3Url, web3: web3, ns: ns)

proc init*(T: type Eth1Monitor,
           db: BeaconChainDB,
           preset: RuntimePreset,
           web3Url: string,
           depositContractAddress: Eth1Address,
           depositContractDeployedAt: BlockHashOrNumber,
           eth1Network: Option[Eth1Network]): Future[Result[T, string]] {.async.} =
  var web3Url = web3Url
  fixupWeb3Urls web3Url

  try:
    let dataProviderRes = await Web3DataProvider.new(depositContractAddress, web3Url)
    if dataProviderRes.isErr:
      return err(dataProviderRes.error)

    let
      dataProvider = dataProviderRes.get
      web3 = dataProvider.web3

    if eth1Network.isSome:
      let
        providerNetwork = await web3.provider.net_version()
        expectedNetwork = case eth1Network.get
          of mainnet: "1"
          of rinkeby: "4"
          of goerli:  "5"
      if expectedNetwork != providerNetwork:
        return err("The specified web3 provider is not attached to the " &
                    $eth1Network.get & " network")

    return ok T(
      db: db,
      preset: preset,
      depositContractDeployedAt: depositContractDeployedAt,
      dataProvider: dataProvider,
      eth1Progress: newAsyncEvent())
  except CatchableError as err:
    return err("Failed to initialize the Eth1 monitor")

proc allDepositsUpTo(m: Eth1Monitor, totalDeposits: uint64): seq[DepositData] =
  for i in 0'u64 ..< totalDeposits:
    result.add m.db.deposits.get(i)

proc createGenesisState(m: Eth1Monitor, eth1Block: Eth1Block): BeaconStateRef =
  notice "Generating genesis state",
    blockNum = eth1Block.number,
    blockHash = eth1Block.voteData.block_hash,
    blockTimestamp = eth1Block.timestamp,
    totalDeposits = eth1Block.voteData.deposit_count,
    activeValidators = eth1Block.activeValidatorsCount

  var deposits = m.allDepositsUpTo(eth1Block.voteData.deposit_count)

  result = initialize_beacon_state_from_eth1(
    m.preset,
    eth1Block.voteData.block_hash,
    eth1Block.timestamp.uint64,
    deposits, {})

  doAssert result.validators.lenu64 == eth1Block.activeValidatorsCount

proc signalGenesis(m: Eth1Monitor, genesisState: BeaconStateRef) =
  m.genesisState = genesisState

  if not m.genesisStateFut.isNil:
    m.genesisStateFut.complete()
    m.genesisStateFut = nil

template hasEnoughValidators(m: Eth1Monitor, blk: Eth1Block): bool =
  blk.activeValidatorsCount >= m.preset.MIN_GENESIS_ACTIVE_VALIDATOR_COUNT

func chainHasEnoughValidators(m: Eth1Monitor): bool =
  if m.eth1Chain.blocks.len > 0:
    m.hasEnoughValidators(m.eth1Chain.blocks[^1])
  else:
    m.eth1Chain.knownStart.deposit_count >=
      m.preset.MIN_GENESIS_ACTIVE_VALIDATOR_COUNT

func isAfterMinGenesisTime(m: Eth1Monitor, blk: Eth1Block): bool =
  doAssert blk.timestamp != 0
  let t = genesis_time_from_eth1_timestamp(m.preset, uint64 blk.timestamp)
  t >= m.preset.MIN_GENESIS_TIME

func isGenesisCandidate(m: Eth1Monitor, blk: Eth1Block): bool =
  m.hasEnoughValidators(blk) and m.isAfterMinGenesisTime(blk)

proc findGenesisBlockInRange(m: Eth1Monitor, startBlock, endBlock: Eth1Block):
                             Future[Eth1Block] {.async.} =
  doAssert startBlock.timestamp != 0 and not m.isAfterMinGenesisTime(startBlock)
  doAssert endBlock.timestamp != 0 and m.isAfterMinGenesisTime(endBlock)
  doAssert m.hasEnoughValidators(startBlock)
  doAssert m.hasEnoughValidators(endBlock)

  var
    startBlock = startBlock
    endBlock = endBlock
    depositData = startBlock.voteData
    activeValidatorsCountDuringRange = startBlock.activeValidatorsCount

  while startBlock.number + 1 < endBlock.number:
    let
      MIN_GENESIS_TIME = m.preset.MIN_GENESIS_TIME
      startBlockTime = genesis_time_from_eth1_timestamp(m.preset, startBlock.timestamp)
      secondsPerBlock = float(endBlock.timestamp - startBlock.timestamp) /
                        float(endBlock.number - startBlock.number)
      blocksToJump = max(float(MIN_GENESIS_TIME - startBlockTime) / secondsPerBlock, 1.0)
      candidateNumber = min(endBlock.number - 1, startBlock.number + blocksToJump.uint64)
      candidateBlock = await m.dataProvider.getBlockByNumber(candidateNumber)

    var candidateAsEth1Block = Eth1Block(number: candidateBlock.number.uint64,
                                         timestamp: candidateBlock.timestamp.uint64,
                                         voteData: depositData)
    candidateAsEth1Block.voteData.block_hash = candidateBlock.hash.asEth2Digest

    let candidateGenesisTime = genesis_time_from_eth1_timestamp(
      m.preset, candidateBlock.timestamp.uint64)

    notice "Probing possible genesis block",
      `block` = candidateBlock.number.uint64,
      candidateGenesisTime

    if candidateGenesisTime < MIN_GENESIS_TIME:
      startBlock = candidateAsEth1Block
    else:
      endBlock = candidateAsEth1Block

  if endBlock.activeValidatorsCount == 0:
    endBlock.activeValidatorsCount = activeValidatorsCountDuringRange

  return endBlock

proc safeCancel(fut: var Future[void]) =
  if not fut.isNil and not fut.finished:
    fut.cancel()
  fut = nil

proc stop*(m: Eth1Monitor) =
  safeCancel m.runFut

const
  votedBlocksSafetyMargin = 20

proc earliestBlockOfInterest(m: Eth1Monitor): Eth1BlockNumber =
  m.latestEth1BlockNumber - (2 * m.preset.ETH1_FOLLOW_DISTANCE) - votedBlocksSafetyMargin

proc syncBlockRange(m: Eth1Monitor,
                    fromBlock, toBlock,
                    fullSyncFromBlock: Eth1BlockNumber) {.async.} =
  doAssert m.eth1Chain.blocks.len > 0

  var currentBlock = fromBlock
  while currentBlock <= toBlock:
    var
      depositLogs: JsonNode = nil
      blocksPerRequest = 5000'u64 # This is roughly a day of Eth1 blocks
      maxBlockNumberRequested: Eth1BlockNumber

    while true:
      maxBlockNumberRequested = min(toBlock, currentBlock + blocksPerRequest - 1)

      debug "Obtaining deposit log events",
            fromBlock = currentBlock,
            toBlock = maxBlockNumberRequested
      try:
        debug.logTime "Deposit logs obtained":
          depositLogs = await m.dataProvider.ns.getJsonLogs(
            DepositEvent,
            fromBlock = some blockId(currentBlock),
            toBlock = some blockId(maxBlockNumberRequested))
        currentBlock = maxBlockNumberRequested + 1
        break
      except CatchableError as err:
        blocksPerRequest = blocksPerRequest div 2
        if blocksPerRequest == 0:
          raise err

    debug.logTime "Deposits grouped in blocks":
      let eth1Blocks = depositEventsToBlocks(depositLogs)

    for i in 0 ..< eth1Blocks.len:
      # TODO(zah): The DB operations should be executed as a transaction here
      let blk = eth1Blocks[i]

      debug.logTime "Deposits persisted":
        for deposit in blk.deposits:
          m.db.processDeposit(deposit.data)

      blk.voteData.deposit_count =
        m.db.finalizedEth1DepositsMerkleizer.totalChunks

      blk.voteData.deposit_root =
        m.db.finalizedEth1DepositsMerkleizer.getDepositsRoot

      blk.activeValidatorsCount = m.db.immutableValidatorData.lenu64

      if blk.number > fullSyncFromBlock:
        let lastBlock = m.eth1Chain.blocks.peekLast
        for n in max(lastBlock.number + 1, fullSyncFromBlock) ..< blk.number:
          let blockWithoutDeposits = await m.dataProvider.getBlockByNumber(n)
          m.eth1Chain.addBlock(
            lastBlock.makeSuccessorWithoutDeposits(blockWithoutDeposits))

      m.eth1Chain.addBlock blk

    if eth1Blocks.len > 0:
      let lastIdx = eth1Blocks.len - 1
      template lastBlock: auto = eth1Blocks[lastIdx]

      when hasDepositRootChecks:
        let status = await m.dataProvider.fetchDepositContractData(lastBlock)
        debug "Deposit contract state verified", status,
              ourCount = lastBlock.voteData.deposit_count,
              ourRoot = lastBlock.voteData.deposit_root

        if status in {DepositRootIncorrect, DepositCountIncorrect}:
          raise newException(CorruptDataProvider,
            "The deposit log events disagree with the deposit contract state")

      m.db.putEth1PersistedTo lastBlock.voteData

      notice "Eth1 sync progress",
             blockNumber = lastBlock.number,
             depositsProcessed = lastBlock.voteData.deposit_count

    if m.genesisStateFut != nil and m.chainHasEnoughValidators:
      let lastIdx = m.eth1Chain.blocks.len - 1
      template lastBlock: auto = m.eth1Chain.blocks[lastIdx]

      if maxBlockNumberRequested == toBlock and
         (m.eth1Chain.blocks.len == 0 or lastBlock.number != toBlock):
        let web3Block = await m.dataProvider.getBlockByNumber(toBlock)

        debug "Latest block doesn't hold deposits. Obtaining it",
               ts = web3Block.timestamp.uint64,
               number = web3Block.number.uint64

        m.eth1Chain.addBlock lastBlock.makeSuccessorWithoutDeposits(web3Block)
      else:
        await m.dataProvider.fetchTimestamp(lastBlock)

      var genesisBlockIdx = m.eth1Chain.blocks.len - 1
      if m.isAfterMinGenesisTime(m.eth1Chain.blocks[genesisBlockIdx]):
        for i in 1 ..< eth1Blocks.len:
          let idx = (m.eth1Chain.blocks.len - 1) - i
          let blk = m.eth1Chain.blocks[idx]
          await m.dataProvider.fetchTimestamp(blk)
          if m.isGenesisCandidate(blk):
            genesisBlockIdx = idx
          else:
            break
        # We have a candidate state on our hands, but our current Eth1Chain
        # may consist only of blocks that have deposits attached to them
        # while the real genesis may have happened in a block without any
        # deposits (triggered by MIN_GENESIS_TIME).
        #
        # This can happen when the beacon node is launched after the genesis
        # event. We take a short cut when constructing the initial Eth1Chain
        # by downloading only deposit log entries. Thus, we'll see all the
        # blocks with deposits, but not the regular blocks in between.
        #
        # We'll handle this special case below by examing whether we are in
        # this potential scenario and we'll use a fast guessing algorith to
        # discover the ETh1 block with minimal valid genesis time.
        var genesisBlock = m.eth1Chain.blocks[genesisBlockIdx]
        if genesisBlockIdx > 0:
          let genesisParent = m.eth1Chain.blocks[genesisBlockIdx - 1]
          if genesisParent.timestamp == 0:
            await m.dataProvider.fetchTimestamp(genesisParent)
          if m.hasEnoughValidators(genesisParent) and
             genesisBlock.number - genesisParent.number > 1:
            genesisBlock = await m.findGenesisBlockInRange(genesisParent,
                                                           genesisBlock)
        m.signalGenesis m.createGenesisState(genesisBlock)

proc handleEth1Progress(m: Eth1Monitor) {.async.} =
  # ATTENTION!
  # Please note that this code is using an async event in order
  # to guarantee the strict serial order of processing of deposits.
  # If we had the same code embedded in the new block headers event,
  # it could easily re-order the steps due to the interruptible
  # interleaved execution of async code.

  let startBlock = awaitWithTimeout(
    m.dataProvider.getBlockByHash(m.eth1Chain.knownStart.block_hash.asBlockHash),
    web3Timeouts):
      error "Eth1 sync failed to obtain information about the starting block in time"
      return

  m.eth1Chain.addBlock Eth1Block(
    number: Eth1BlockNumber startBlock.number,
    timestamp: Eth1BlockTimestamp startBlock.timestamp,
    voteData: m.eth1Chain.knownStart)

  var eth1SyncedTo = Eth1BlockNumber startBlock.number

  while true:
    if bnStatus == BeaconNodeStatus.Stopping:
      if not m.genesisStateFut.isNil:
        m.genesisStateFut.complete()
        m.genesisStateFut = nil
      m.stop()
      return

    await m.eth1Progress.wait()
    m.eth1Progress.clear()

    if m.latestEth1BlockNumber <= m.preset.ETH1_FOLLOW_DISTANCE:
      continue

    let targetBlock = m.latestEth1BlockNumber - m.preset.ETH1_FOLLOW_DISTANCE
    if targetBlock <= eth1SyncedTo:
      continue

    let earliestBlockOfInterest = m.earliestBlockOfInterest()
    await m.syncBlockRange(eth1SyncedTo + 1, targetBlock, earliestBlockOfInterest)
    eth1SyncedTo = targetBlock

    # We'll clean old blocks that can no longer be voting candidates.
    # Technically, we should check that the block is outside of the current
    # voting period as determined by its timestamp, but we'll approximate
    # this by requiring a much larger difference in block numbers:
    while m.eth1Chain.blocks.len > 1:
      let earliestBlock = m.eth1Chain.blocks.peekFirst
      if earliestBlock.number > earliestBlockOfInterest:
        break
      m.eth1Chain.popFirst()

proc run(m: Eth1Monitor, delayBeforeStart: Duration) {.async.} =
  if delayBeforeStart != ZeroDuration:
    await sleepAsync(delayBeforeStart)

  info "Starting Eth1 deposit contract monitoring",
    contract = $m.depositContractAddress, url = m.web3Url

  let previouslyPersistedTo = m.db.getEth1PersistedTo()
  m.eth1Chain.knownStart = previouslyPersistedTo.get:
    # `previouslyPersistedTo` wall null, we start from scratch
    let deployedAtHash = if m.depositContractDeployedAt.isHash:
      m.depositContractDeployedAt.hash
    else:
      var blk: BlockObject
      while true:
        try:
          blk = await m.dataProvider.getBlockByNumber(m.depositContractDeployedAt.number)
          break
        except CatchableError as err:
          error "Failed to obtain details for the starting block " &
                "of the deposit contract sync. The Web3 provider " &
                "may still be not fully synced", error = err.msg
        await sleepAsync(chronos.seconds(10))
        # TODO: After a single failure, the web3 object may enter a state
        #       where it's no longer possible to make additional requests.
        #       Until this is fixed upstream, we'll just try to recreate
        #       the web3 provider before retrying. In case this fails,
        #       the Eth1Monitor will be restarted.
        m.dataProvider = tryGet(await Web3DataProvider.new(
          m.depositContractAddress,
          m.web3Url))
      blk.hash.asEth2Digest
    Eth1Data(block_hash: deployedAtHash, deposit_count: 0)

  await m.dataProvider.onBlockHeaders do (blk: Eth1BlockHeader)
                                         {.raises: [Defect], gcsafe.}:
    try:
      if blk.number.uint64 > m.latestEth1BlockNumber:
        m.latestEth1BlockNumber = blk.number.uint64
        m.eth1Progress.fire()
    except Exception:
      # TODO Investigate why this exception is being raised
      raiseAssert "AsyncEvent.fire should not raise exceptions"
  do (err: CatchableError):
    debug "Error while processing Eth1 block headers subscription", err = err.msg

  await m.handleEth1Progress()

proc start(m: Eth1Monitor, delayBeforeStart: Duration) =
  if m.runFut.isNil:
    let runFut = m.run(delayBeforeStart)
    m.runFut = runFut
    runFut.addCallback do (p: pointer):
      if runFut.failed:
        if runFut.error[] of CatchableError:
          if runFut == m.runFut:
            error "Eth1 chain monitoring failure, restarting", err = runFut.error.msg
            m.stop()
        else:
          fatal "Fatal exception reached", err = runFut.error.msg
          quit 1

      m.runFut = nil
      m.start(5.seconds)

proc start*(m: Eth1Monitor) =
  m.start(0.seconds)

proc waitGenesis*(m: Eth1Monitor): Future[BeaconStateRef] {.async.} =
  if m.genesisState.isNil:
    m.start()

    if m.genesisStateFut.isNil:
      m.genesisStateFut = newFuture[void]("waitGenesis")

    info "Awaiting genesis event"
    await m.genesisStateFut
    m.genesisStateFut = nil

  if m.genesisState != nil:
    return m.genesisState
  else:
    doAssert bnStatus == BeaconNodeStatus.Stopping
    return new BeaconStateRef # cannot return nil...

proc getEth1BlockHash*(url: string, blockId: RtBlockIdentifier): Future[BlockHash] {.async.} =
  let web3 = await newWeb3(url)
  try:
    let blk = await web3.provider.eth_getBlockByNumber(blockId, false)
    return blk.hash
  finally:
    await web3.close()

