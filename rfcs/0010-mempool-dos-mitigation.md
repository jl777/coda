## Mitigations for DOS attacks based on bogus transactions
[summary]: #summary

We add some rules for deciding whether to store incoming transactions in the
mempool and gossip them. FIXME details.


## Motivation

[motivation]: #motivation

Every transaction consumes resources: computation, storage, and bandwidth. In
the case of transactions that are eventually included in a block, those
resources are priced by transaction fees. But transactions that are never
included in a block don't pay transaction fees, so without good design bogus
transactions could be a vector for cheap DoS attacks. We want to make sure it
costs enough to make nodes consume resources that a DoS attack is too expensive
to be worthwhile.

(The transaction fees for *mined* transactions may or may not accurately reflect
the total cost to all network participants for processing the transaction, but
that's a problem for another day.)

We can't control what transactions we receive, but we can control whether we
store them and whether we forward them on, making other nodes deal with them.

## Detailed design

[detailed-design]: #detailed-design

As a general principle, we want to accept transactions into the mempool iff they
will eventually be mined into a future block. That's the purpose of the mempool.
For DoS protection, we assume that the cost of including a transaction in a
block is sufficient to deter DoS attacks on proposers, since the cost of
creating a SNARK greatly exceeds the cost of checking and storing an incoming
transaction. Where possible, we prefer to charge for things rather than banning
them. We don't mind if someone uses a lot of resources, so long as those
resources are paid for at a price that network participants would be happy with.

### When we first recieve a transaction: rules

When we receive a gossiped transaction, we will check the below constraints. If
any of the checks fail, we ignore the transaction and do not gossip it.

* Validity:
  1. The signature.
  2. The sender's account exists.
  3. The sender's balance (inclusive of any pending txs from the same account
  with lower nonce) is >= the transaction amount + fee.
  4. The tx nonce is equal to the sending account's next nonce, inclusive of
  transactions already in the mempool. (If it conflicts with one in the mempool,
  see below.)
* Mining probability:
  1. The (adjusted?) fee is >= the lowest fee paid in a transaction included in
     the last `min_fee_window` blocks, times `min_fee_discount_factor`, a value
     in the interval (0,1). FIXME: This minimum is attacker controlled. An
     attacker who wins at least one slot and proves one SNARK can set it to
     zero. Can't use a (exponentially weighted) moving average either, for the
     opposite issue. Maybe don't do a set minimum and rely on the fee rules for
     when the pool is full?

If we get any transactions where the signature is invalid, we blacklist the
sending node immediately. No honest node sends transactions like that. If we get
transactions that fail for other reasons - the ones that depend on the current
chain state - then we blacklist the node after `bad_tx_blacklist_limit` bad
transactions (FIXME use pre-existing banlist and scores?). Honest nodes that are
out of date might innocently send us transactions that are not valid, but they
won't send us a lot of them. If a node detects it is substantially behind the
network, it should disable gossip until it catches up.

#### Replacing transactions

A useful feature of existing cryptocurrencies is the ability to replace a
pending transaction with a different one by broadcasting a new one with the same
nonce. Users can e.g. cancel payments by replacing them with a no-op transaction
(send themselves $0) or resend them with a higher fee if they're processing too
slow.

We want to have this feature, but it allows an attacker to make proposers
process transactions which won't eventually get mined (the ones that are
replaced), which violates our first guiding principle. So we require an added
fee, `mempool_replace_fee`, representing the cost to the network to process and
store a pending transaction, and add a field to transaction payloads counting
the number of replacements that occurred for a given nonce. A transaction's
total fee is its original transaction fee plus the replacement count times
`mempool_replace_fee`. If a node receives a new transaction with the same nonce
and sender account as one in the mempool, it looks at the replacement count and
checks if it is different from the replacement counts of all the transactions
from that account/nonce pair it's seen so far. If it is, and the fee is higher
it will include that transaction in the next block it mines. If the
account/nonce/replacement count triple has been seen before then we know the
payment sender is attempting to cheat and has sent two or more transactions
without paying the correct replacement fee.

In that case, we punish the *sender*. It's not possible to solve this problem by
blacklisting peers, because peers may not be aware that a transaction is an
illegal duplicate. Imagine Mallory connects to two proposers, Alice and Bob. She
sends two different transactions, both with nonce n, to Alice and Bob
simultaneously. Alice and Bob gossip these new transactions to each other, and
both think their peer is sending them an invalid transaction. If we used peer
blacklisting here, Mallory could cause Alice and Bob to blacklist each other,
even though they were both acting honestly.

To punish the sender, we require senders to "deposit" an amount equal to
twice the transaction fee when sending any transaction. We also add a new type
of transaction, a fraud proof, that proves a sender sent two or more
transactions with the same account/nonce/replacement count triple, by supplying
the two transactions. If one of these transactions is included in the
blockchain, the miner gets the deposit. If no such transaction is included after
`fraud_proof_window`, the deposit is returned. The deposit is twice the
transaction fee because if it's forfeited we need to eventually make a SNARK
that checks two transactions. We rely again on the fact that SNARK proving is
much more expensive than transaction processing. This scheme has the unfortunate
downside that we need to track when deposits are returned to keep balances up to
date. Not sure how much overhead that adds.

#### Multiple pending transactions from the same account

Since payments aren't instant, users may want to queue multiple outgoing
transactions. This listed rules above cover this case, but things get
complicated when you allow transaction replacement. I'm not sure how to resolve
it yet. Imagine Mallory broadcasts 1000 valid transactions with sequential
nonces, then replaces the first one with one that spends all the money in the
account. The other 999 of them are now invalid and won't be mined, but the
proposers still had to validate, store and gossip them, violating our first
principle. If she had to pay 1000 times `mempool_replace_fee` that would be
fine, but how do we construct the fraud proofs? The trick where we just show a
pair of signed payments with the same account/nonce/replacement count triple
doesn't work if some payments need to pay multiples of the repleacment fee.

### When mempool size is exceeded: rules

We have a set limit on mempool size: `max_mempool_size`, in bytes (FIXME
transaction count?). If an incoming transaction would cause us to exceed the
limit, we evict the lowest fee transaction from the mempool, or drop the
incoming transaction if its fee is <= the lowest fee transaction in the mempool.

When one node connects to another for gossip purposes, they need to exchange the
minimum fee they're willing to accept i.e. the lowest (adjusted?) fee currently
in their mempools or the minimum fee determined by the procedure above,
whichever is greater, and keep that updated as long as the connection is live.
Since nodes will have different mempools and hence different minimum fees, they
need to not send each other transactions that the other won't accept. If a node
receives a transaction with a lower fee that the communicated minimum, it should
blacklist the peer (subject to network delay - we shouldn't blacklist the peer
if it didn't receive our new minimum before it sent the transaction). If we
didn't do this, an attacker could get a node to receive and process transactions
that it would never include in a block, for free. If we blacklisted nodes for
sending low fee transactions without communicating our minimums, nodes would
blacklist peers simply because the peer had a less full mempool.

### Efficient implementation

FIXME

### Constants

* `mempool_replace_fee`: This is the cost of validating the new transaction, not
  the cost of including it in the blockchain and eventually building a SNARK for
  it. So it should be very low. Assuming it takes 10ms to validate a transaction
  (hopefully that is way high), and there are 1000 block proposers keeping
  mempools, we have 10s of total CPU time per incoming tx. Amazon charges
  $0.0255/hr for an `a1.medium` EC2 instance with one vCPU. Doing the math, 10s
  costs $0.00007. FIXME do we want to somehow fetch a USD-CODA exchange rate and
  dynamically update this, or is it sufficient if this is a fixed global parameter?
* `min_fee_discount_factor`: This must be in then interval (0, 1). If it's zero
  it's as though we didn't have one, and attackers can send transactions for
  free. If it's >= 1 then it's a ratchet: the minimum fee can only go up. We
  want it to go down when load decreases, SNARK proving gets more efficient,
  etc. N.B. This and `min_fee_window` only matter in situations where the node's
  mempool isn't full.
* `min_fee_window`: Along with `max_mempool_size`, this determines how long
  transactions can wait in the mempool before being added to a block. We expect
  transaction flow to be bursty, and for users to have different preferences re
  transaction latency. If we assume that if a transaction with a fee of x was
  mined n blocks ago it's likely that another transaction with a fee of x will
  be mined in the next n blocks, which I think is mostly true, then
  `min_fee_window` should be approximately the maximum wait time. Let's set it
  to one hour's worth of blocks.
* `bad_tx_blacklist_limit`: There are two situations where honest nodes send us
  bad transactions. The first is when they are slightly behind us on the
  consensus state, which is going to happen all the time just because of network
  delay. The second is when they are substantially out of sync but haven't
  noticed yet. After they notice they're supposed to disable gossip until
  they're caught up. Maybe this should be a fraction rather than a limit? A node
  that sends 95% valid transactions is probably just reflecting normal network
  delay, and one that sends 0% is probably malicious. If it were a fixed limit,
  we'd eventually blacklist all long lived peers if they have any substantial
  delay. FIXME I guess.
* `fraud_proof_window`: This needs to be > 0 in case our attacker is a block
  proposer or is collaborating with one. In that situation, she can time her
  attack so it occurs immediately before a slot she won. She sends different
  transactions to Alice and Bob, then publishes a block containing a third
  transaction. If Alice and Bob gossip their transactions, they can each create
  a fraud proof, but since a transaction has gone through already it's not worth
  anything. So the window is something like how many slots in a row we expect an
  adversary to control plus network delay sufficient for proposers to have the
  duplicates in hand.
* `max_mempool_size`: Not sure about this one yet.

This is the technical portion of the RFC. Explain the design in sufficient detail that:

* Its interaction with other features is clear.
* It is reasonably clear how the feature would be implemented.
* Corner cases are dissected by example.

## Drawbacks
[drawbacks]: #drawbacks

Complexity. Maybe overhead? This needs more thought.

## Rationale and alternatives
[rationale-and-alternatives]: #rationale-and-alternatives

* Why is this design the best in the space of possible designs?
* What other designs have been considered and what is the rationale for not choosing them?
  * Allow pending txs that spend money not (yet) in the sender's account

    Ethereum does this. It's abusable, an attacker can send transactions that
    will never be mined. The countermeasure is having a hard limit on pending
    transactions per account, which I don't like:
  * Max pending tx per account

    There are legitimate use cases for sending lots of transactions from one
    address rapidly, and I strongly prefer charging for things to banning
    things. For an example, imagine an exchange. To process withdrawals they may
    need to send 100s of transactions per minute from a single address. So long
    as that is priced efficiently they shoud be able to do so. Yes, they should
    probably be doing transaction batching in this scenario, but it's better
    that doing individual transactions is expensive than if it were impossible.
  * Skip validation for speed

    This is (partly) what we do now, and is vulnerable to all sorts of stuff.
  * Fancy machine learning for predicting whether the tx will be mined

    This might be a solution to the questions wrt to minimum fees when the pool
    isn't full, but my feeling is there are simple-ish rules that capture what
    we want and doing ML is a rabbit hole of complexity.
  * Block lookback window for validity.

    Part of Brandon's original plan was to accept transactions that were valid
    at any point in the transition frontier, or within some fixed lookback from
    a current tip. This is abusable. Mallory can move funds around such that she
    can make transactions that were valid recently but aren't now, and consume
    resources for free. The attack requires her to move them around at least
    once every lookback window blocks, and lets her consume resources for
    lookback window blocks, so with a sufficiently small window it's probably
    impractical, but I'd rather avoid the headache. I don't see a use case for
    it. Since the account holder is the only one who can spend funds from their
    account, and since insufficient funds is (almost) the only reason payments
    can fail, they should never be sending transactions that used to be valid
    but aren't now.
  * No minimum fee, rely only on finite mempool size

    I'm not sure this is actually the wrong thing to do now, but the downside is
    that attackers may force us to store/validate/gossip lots of transactions
    up until the point that our mempool is full.
* What is the impact of not doing this?

  Various vulnerabilities.

## Prior art
[prior-art]: #prior-art

Ethereum allows transaction replacement, and multiple pending transactions from
the same account, without requiring they be valid when run sequentially. If a
transaction's smart contract errors out, or runs out of gas, miners get to keep
the fees. So it's sort of a like a deposit. But I don't think they check that
the there's sufficient balance in the account to cover the sum of transaction
fees from all pending transactions before accepting another transaction. That
would be expensive, since the balance of the sending account after a transaction
runs may be higher than when it started due to smart contracts. There's no
explicit replacement fee, and there's definitely no deposit system for it. There
might be a minimum fee increment though. I think they're vulnerable to some of
these attacks. They evict transactions from the mempool on a lowest-fee-first
basis.

Bitcoin will do what they call "replace-by-fee" which is the transaction
replacement thing. They may have a minimum increment, but not a deposit system.
Transactions are evicted on a lowest-fee-first basis. They allow mempool
transactions to depend on each other, but not on hypothetical future
transactions. When a transaction is evicted from the mempool, they also evict
any transactions that depend on it.

## Unresolved questions
[unresolved-questions]: #unresolved-questions

* What parts of the design do you expect to resolve through the RFC process
  before this gets merged?

  Everything with a question mark or a FIXME. I also need a decent sketch of
  what an efficient implementation would look like. If some of these things turn
  out to be super expensive, it'll influence design.

* What parts of the design do you expect to resolve through the implementation
  of this feature before merge?

* What related issues do you consider out of scope for this RFC that could be
  addressed in the future independently of the solution that comes out of this
  RFC?
  
  The SNARK pool has similar concerns.
