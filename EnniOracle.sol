// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IChronicle {
    function readWithAge() external view returns (uint256 value, uint256 age);
    function decimals() external view returns (uint8);
}

contract EnniOracleV1 {
    AggregatorV3Interface public immutable CHAINLINK;
    IChronicle public immutable CHRONICLE;

    /// @notice Optional Chainlink translator (e.g. JPY/USD, EUR/USD, CHF/USD).
    ///         address(0) = no translation, pure ETH/USD.
    AggregatorV3Interface public immutable TRANSLATOR;

    uint256 public constant STALE_CHAINLINK  = 6 hours;
    uint256 public constant STALE_CHRONICLE  = 24 hours;
    uint256 public constant STALE_TRANSLATOR = 24 hours;

    uint256 public lastGoodPrice;
    uint256 public lastGoodUpdatedAt;

    enum Source { None, Chainlink, Chronicle, Cached }

    event PriceUpdated(Source source, uint256 price, uint256 timestamp);

    error OracleUnavailable();

    constructor(
        address chainlinkEthUsd,
        address chronicleEthUsd,
        address translator           // address(0) = no translation
    ) {
        CHAINLINK  = AggregatorV3Interface(chainlinkEthUsd);
        CHRONICLE  = IChronicle(chronicleEthUsd);
        TRANSLATOR = AggregatorV3Interface(translator);

        require(CHRONICLE.decimals() == 18, "Chronicle decimals != 18");

        (bool ok, uint256 p, uint256 ts, ) = _readBest();
        if (!ok) revert OracleUnavailable();

        lastGoodPrice = p;
        lastGoodUpdatedAt = ts;

        require(lastGoodPrice > 0);
    }

    // ─── Public view ────────────────────────────────────────────────

    function peekPrice() external view returns (uint256) {
        (bool ok, uint256 p, , ) = _readBest();
        if (ok) return p;

        uint256 cached = lastGoodPrice;
        if (cached == 0) revert OracleUnavailable();
        return cached;
    }

    function peekPriceWithTimestamp() external view returns (uint256 price, uint256 updatedAt) {
        (bool ok, uint256 p, uint256 ts, ) = _readBest();
        if (ok) return (p, ts);

        uint256 cached = lastGoodPrice;
        uint256 cachedTs = lastGoodUpdatedAt;
        if (cached == 0) revert OracleUnavailable();
        return (cached, cachedTs);
    }

    // ─── State-changing ─────────────────────────────────────────────

    function fetchPrice() external returns (uint256) {
        (bool ok, uint256 p, uint256 ts, Source src) = _readBest();

        uint256 cached = lastGoodPrice;

        if (ok) {
            uint256 lastTs = lastGoodUpdatedAt;

            if (ts <= lastTs) {
                if (cached == 0) revert OracleUnavailable();
                return cached;
            }

            lastGoodPrice = p;
            lastGoodUpdatedAt = ts;
            emit PriceUpdated(src, p, ts);
            return p;
        }

        if (cached == 0) revert OracleUnavailable();
        emit PriceUpdated(Source.Cached, cached, lastGoodUpdatedAt);
        return cached;
    }

    // ─── Helpers ────────────────────────────────────────────────────

    function cachedPrice() external view returns (uint256, uint256) {
        return (lastGoodPrice, lastGoodUpdatedAt);
    }

    function readChainlink() external view returns (bool ok, uint256 price, uint256 updatedAt) {
        return _readChainlinkFeed(CHAINLINK, STALE_CHAINLINK);
    }

    function readChronicle() external view returns (bool ok, uint256 price, uint256 updatedAt) {
        return _readChronicle();
    }

    function readTranslator() external view returns (bool ok, uint256 price, uint256 updatedAt) {
        if (address(TRANSLATOR) == address(0)) return (false, 0, 0);
        return _readChainlinkFeed(TRANSLATOR, STALE_TRANSLATOR);
    }

    function hasTranslator() external view returns (bool) {
        return address(TRANSLATOR) != address(0);
    }

    // ─── Internal ───────────────────────────────────────────────────

    function _readBest() internal view returns (bool, uint256, uint256, Source) {
        (bool okCl, uint256 pCl, uint256 tCl) = _readChainlinkFeed(CHAINLINK, STALE_CHAINLINK);
        if (okCl) {
            (bool tok, uint256 tp, uint256 tt) = _translate(pCl, tCl);
            if (tok) return (true, tp, tt, Source.Chainlink);
        }

        (bool okCh, uint256 pCh, uint256 tCh) = _readChronicle();
        if (okCh) {
            (bool tok2, uint256 tp2, uint256 tt2) = _translate(pCh, tCh);
            if (tok2) return (true, tp2, tt2, Source.Chronicle);
        }

        return (false, 0, 0, Source.None);
    }

    /// @dev If TRANSLATOR is set: price = basePrice / fxRate, timestamp = min(baseTs, fxTs).
    ///      If TRANSLATOR is address(0): passthrough.
    function _translate(uint256 basePrice, uint256 baseTs)
        internal view returns (bool, uint256, uint256)
    {
        if (address(TRANSLATOR) == address(0)) return (true, basePrice, baseTs);

        (bool ok, uint256 fx, uint256 fxTs) = _readChainlinkFeed(TRANSLATOR, STALE_TRANSLATOR);
        if (!ok) return (false, 0, 0);

        uint256 translated = (basePrice * 1e18) / fx;
        if (translated == 0) return (false, 0, 0);

        uint256 minTs = baseTs < fxTs ? baseTs : fxTs;
        return (true, translated, minTs);
    }

    /// @dev Shared Chainlink reader — used for both primary ETH/USD and translator feed.
    function _readChainlinkFeed(AggregatorV3Interface feed, uint256 staleThreshold)
        internal view returns (bool, uint256, uint256)
    {
        uint8 dec;
        try feed.decimals() returns (uint8 d) {
            dec = d;
        } catch {
            return (false, 0, 0);
        }

        try feed.latestRoundData()
            returns (
                uint80 roundId,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80 answeredInRound
            )
        {
            if (
                roundId == 0 ||
                answeredInRound < roundId ||
                answer <= 0 ||
                updatedAt == 0 ||
                updatedAt > block.timestamp ||
                block.timestamp - updatedAt > staleThreshold
            ) return (false, 0, 0);

            return (true, _scaleTo18(uint256(answer), dec), updatedAt);
        } catch {
            return (false, 0, 0);
        }
    }

    function _readChronicle() internal view returns (bool, uint256, uint256) {
        uint256 val;
        uint256 ts;

        try CHRONICLE.readWithAge() returns (uint256 v, uint256 a) {
            val = v;
            ts = a;
        } catch {
            return (false, 0, 0);
        }

        if (
            val == 0 ||
            ts == 0 ||
            ts > block.timestamp ||
            block.timestamp - ts > STALE_CHRONICLE
        ) return (false, 0, 0);

        return (true, val, ts);
    }

    function _scaleTo18(uint256 price, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return price;
        if (dec < 18) return price * (10 ** (18 - dec));
        return price / (10 ** (dec - 18));
    }
}