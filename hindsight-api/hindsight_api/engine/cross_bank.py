"""
Cross-bank orchestration for Hindsight memory system.

This module provides the CrossBankOrchestrator which coordinates queries
across multiple memory banks, handling bank selection, budget allocation,
and result fusion.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from hindsight_api.api.cross_bank_models import (
        BankInfo,
        CrossBankFact,
        CrossBankRecallResult,
        CrossBankReflectResult,
    )
    from hindsight_api.config_resolver import ConfigResolver
    from hindsight_api.engine.memory_engine import Budget
    from hindsight_api.models import RequestContext


# =============================================================================
# Budget Allocation
# =============================================================================


class BudgetStrategy(str, Enum):
    """Strategies for allocating budget across banks."""

    EQUAL = "equal"  # Split budget equally across all banks
    PROPORTIONAL = "proportional"  # Allocate based on bank memory counts
    QUERY_RELEVANT = "query_relevant"  # Allocate based on estimated query relevance


@dataclass
class BudgetAllocation:
    """Result of budget allocation across banks."""

    per_bank: dict[str, int]  # bank_id -> token budget
    total_used: int
    strategy: BudgetStrategy
    synthesis_reserve: int = 0  # Tokens reserved for final synthesis (multi-step)


class BudgetAllocator:
    """
    Allocates query budget across multiple banks.

    Supports different allocation strategies to optimize
    cross-bank query performance.
    """

    SYNTHESIS_RESERVE_RATIO = 0.30  # Reserve 30% for synthesis in multi-step

    @staticmethod
    def equal_split(budget_value: int, bank_ids: list[str]) -> BudgetAllocation:
        """
        Split budget equally across all banks.

        Args:
            budget_value: Total budget tokens to allocate.
            bank_ids: List of bank IDs to allocate budget for.

        Returns:
            BudgetAllocation with equal per-bank amounts.
        """
        if not bank_ids:
            return BudgetAllocation(per_bank={}, total_used=0, strategy=BudgetStrategy.EQUAL)

        per_bank = int(budget_value / len(bank_ids))
        allocation = {bank_id: per_bank for bank_id in bank_ids}
        total_used = per_bank * len(bank_ids)

        return BudgetAllocation(
            per_bank=allocation,
            total_used=total_used,
            strategy=BudgetStrategy.EQUAL,
        )

    @staticmethod
    def proportional(
        budget_value: int,
        bank_sizes: dict[str, int],
    ) -> BudgetAllocation:
        """
        Allocate budget proportional to bank memory counts.

        Banks with more memories get larger budget allocations.

        Args:
            budget_value: Total budget tokens to allocate.
            bank_sizes: Dict mapping bank_id to memory count.

        Returns:
            BudgetAllocation weighted by bank sizes.
        """
        if not bank_sizes:
            return BudgetAllocation(per_bank={}, total_used=0, strategy=BudgetStrategy.PROPORTIONAL)

        total_memories = sum(bank_sizes.values())
        if total_memories == 0:
            return BudgetAllocator.equal_split(budget_value, list(bank_sizes.keys()))

        allocation = {}
        total_used = 0
        for bank_id, size in bank_sizes.items():
            bank_budget = int(budget_value * (size / total_memories))
            allocation[bank_id] = bank_budget
            total_used += bank_budget

        return BudgetAllocation(
            per_bank=allocation,
            total_used=total_used,
            strategy=BudgetStrategy.PROPORTIONAL,
        )

    @staticmethod
    def query_relevant(
        budget_value: int,
        bank_relevance: dict[str, float],
    ) -> BudgetAllocation:
        """
        Allocate budget based on estimated query relevance per bank.

        Uses a lightweight pre-query (e.g., BM25) to estimate
        which banks are most relevant to the query.

        Args:
            budget_value: Total budget tokens to allocate.
            bank_relevance: Dict mapping bank_id to relevance score (0-1).

        Returns:
            BudgetAllocation weighted by relevance scores.
        """
        if not bank_relevance:
            return BudgetAllocation(per_bank={}, total_used=0, strategy=BudgetStrategy.QUERY_RELEVANT)

        total_relevance = sum(bank_relevance.values())
        if total_relevance == 0:
            return BudgetAllocator.equal_split(budget_value, list(bank_relevance.keys()))

        allocation = {}
        total_used = 0
        for bank_id, relevance in bank_relevance.items():
            bank_budget = int(budget_value * (relevance / total_relevance))
            allocation[bank_id] = bank_budget
            total_used += bank_budget

        return BudgetAllocation(
            per_bank=allocation,
            total_used=total_used,
            strategy=BudgetStrategy.QUERY_RELEVANT,
        )

    @staticmethod
    def allocate_for_multistep(
        total_budget: int,
        bank_ids: list[str],
        n_steps: int,
    ) -> tuple[BudgetAllocation, int]:
        """
        Allocate budget for multi-step reasoning.

        Reserves a portion for final synthesis and splits
        the remainder across steps and banks.

        Args:
            total_budget: Total budget tokens.
            bank_ids: List of bank IDs.
            n_steps: Number of reasoning steps.

        Returns:
            Tuple of (per_step_allocation, synthesis_budget).
        """
        synthesis_budget = int(total_budget * BudgetAllocator.SYNTHESIS_RESERVE_RATIO)
        remaining = total_budget - synthesis_budget

        per_step_per_bank = int(remaining / (n_steps * len(bank_ids))) if bank_ids and n_steps > 0 else 0
        allocation = {bank_id: per_step_per_bank for bank_id in bank_ids}

        return BudgetAllocation(
            per_bank=allocation,
            total_used=per_step_per_bank * len(bank_ids),
            strategy=BudgetStrategy.EQUAL,
            synthesis_reserve=synthesis_budget,
        ), synthesis_budget


# =============================================================================
# Bank Selection
# =============================================================================


class BankSelector:
    """
    Resolves which banks participate in a cross-bank query.

    Supports selection by explicit IDs, tags, or automatic
    discovery of accessible banks.
    """

    def __init__(self, engine: "MemoryEngineInterface"):
        """
        Initialize the bank selector.

        Args:
            engine: Memory engine instance for bank queries.
        """
        self._engine = engine

    async def resolve(
        self,
        bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        request_context: "RequestContext | None" = None,
    ) -> list["BankInfo"]:
        """
        Resolve the list of banks to query.

        Selection priority:
        1. If bank_ids provided: validate access and return those banks
        2. If bank_tags provided: filter banks by tags
        3. Otherwise: return all accessible banks

        Args:
            bank_ids: Explicit list of bank IDs to query.
            bank_tags: Filter banks by these tags.
            request_context: Request context for authorization.

        Returns:
            List of BankInfo for participating banks.
        """
        # TODO: Implement bank resolution logic
        # This is a stub for Sprint 1 - full implementation in Sprint 2
        raise NotImplementedError("BankSelector.resolve() will be implemented in Sprint 2")

    async def _validate_and_load(
        self,
        bank_ids: list[str],
        request_context: "RequestContext | None",
    ) -> list["BankInfo"]:
        """Validate access to specified banks and load their info."""
        # TODO: Implement validation logic
        raise NotImplementedError("BankSelector._validate_and_load() will be implemented in Sprint 2")

    async def _filter_by_tags(
        self,
        tags: list[str],
        request_context: "RequestContext | None",
    ) -> list["BankInfo"]:
        """Find banks matching any of the specified tags."""
        # TODO: Implement tag filtering
        raise NotImplementedError("BankSelector._filter_by_tags() will be implemented in Sprint 2")

    async def _all_accessible(
        self,
        request_context: "RequestContext | None",
    ) -> list["BankInfo"]:
        """Get all banks accessible to the request context."""
        # TODO: Implement accessible bank discovery
        raise NotImplementedError("BankSelector._all_accessible() will be implemented in Sprint 2")


# =============================================================================
# Disposition Reconciliation
# =============================================================================


@dataclass
class ReconciledDisposition:
    """Result of reconciling dispositions across banks."""

    skepticism: int
    literalism: int
    empathy: int
    reconciliation_method: str
    bank_weights: dict[str, float] = field(default_factory=dict)

    def to_dict(self) -> dict[str, int]:
        """Convert to disposition dict format."""
        return {
            "skepticism": self.skepticism,
            "literalism": self.literalism,
            "empathy": self.empathy,
        }


def reconcile_dispositions(
    bank_results: dict[str, list["CrossBankFact"]],
    bank_dispositions: dict[str, dict[str, int]],
) -> ReconciledDisposition:
    """
    Reconcile conflicting dispositions using relevance-weighted averaging.

    Weight each bank's disposition by how many relevant facts it contributed.

    Args:
        bank_results: Dict mapping bank_id to list of facts returned.
        bank_dispositions: Dict mapping bank_id to disposition traits.

    Returns:
        ReconciledDisposition with weighted average traits.
    """
    if not bank_results or not bank_dispositions:
        return ReconciledDisposition(
            skepticism=3,
            literalism=3,
            empathy=3,
            reconciliation_method="default",
        )

    total_facts = sum(len(facts) for facts in bank_results.values())
    if total_facts == 0:
        return ReconciledDisposition(
            skepticism=3,
            literalism=3,
            empathy=3,
            reconciliation_method="no_facts",
        )

    weighted_skepticism = 0.0
    weighted_literalism = 0.0
    weighted_empathy = 0.0
    bank_weights = {}

    for bank_id, facts in bank_results.items():
        if bank_id not in bank_dispositions:
            continue

        weight = len(facts) / total_facts
        bank_weights[bank_id] = weight

        disposition = bank_dispositions[bank_id]
        weighted_skepticism += disposition.get("skepticism", 3) * weight
        weighted_literalism += disposition.get("literalism", 3) * weight
        weighted_empathy += disposition.get("empathy", 3) * weight

    return ReconciledDisposition(
        skepticism=round(weighted_skepticism),
        literalism=round(weighted_literalism),
        empathy=round(weighted_empathy),
        reconciliation_method="relevance_weighted",
        bank_weights=bank_weights,
    )


# =============================================================================
# Cross-Bank Orchestrator
# =============================================================================


class CrossBankOrchestrator:
    """
    Orchestrates queries across multiple Hindsight banks.

    Coordinates parallel bank queries, result fusion, and
    multi-step reasoning for complex queries.
    """

    def __init__(
        self,
        engine: "MemoryEngineInterface",
        config_resolver: "ConfigResolver | None" = None,
    ):
        """
        Initialize the cross-bank orchestrator.

        Args:
            engine: Memory engine for executing per-bank queries.
            config_resolver: Optional config resolver for hierarchical config.
        """
        self._engine = engine
        self._config_resolver = config_resolver
        self._bank_selector = BankSelector(engine)

    async def cross_bank_recall(
        self,
        query: str,
        bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        max_results: int = 20,
        budget: "Budget | None" = None,
        request_context: "RequestContext | None" = None,
    ) -> "CrossBankRecallResult":
        """
        Recall facts from multiple banks with fused ranking.

        Args:
            query: The search query.
            bank_ids: Specific banks to query (None = all accessible).
            bank_tags: Filter banks by tags.
            max_results: Maximum total results to return.
            budget: Budget level for the query.
            request_context: Request context for authorization.

        Returns:
            CrossBankRecallResult with fused and ranked facts.
        """
        # TODO: Implement full cross-bank recall in Sprint 2
        # Sprint 1: Just return empty result with proper structure
        raise NotImplementedError("CrossBankOrchestrator.cross_bank_recall() will be implemented in Sprint 2")

    async def cross_bank_reflect(
        self,
        query: str,
        bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        budget: "Budget | None" = None,
        context: str | None = None,
        include_mental_models: bool = True,
        include_reasoning_chain: bool = False,
        response_schema: dict | None = None,
        request_context: "RequestContext | None" = None,
    ) -> "CrossBankReflectResult":
        """
        Reflect across multiple banks with disposition-aware synthesis.

        Args:
            query: The question to reflect on.
            bank_ids: Specific banks to query (None = all accessible).
            bank_tags: Filter banks by tags.
            budget: Budget level for the query.
            context: Additional context for the reflection.
            include_mental_models: Whether to consult mental models.
            include_reasoning_chain: Whether to decompose complex queries.
            response_schema: Optional JSON Schema for structured output.
            request_context: Request context for authorization.

        Returns:
            CrossBankReflectResult with synthesized response.
        """
        # TODO: Implement full cross-bank reflect in Sprint 2
        # Sprint 1: Just return empty result with proper structure
        raise NotImplementedError("CrossBankOrchestrator.cross_bank_reflect() will be implemented in Sprint 2")

    async def _parallel_recall(
        self,
        query: str,
        banks: list["BankInfo"],
        budget_allocation: BudgetAllocation,
        request_context: "RequestContext",
    ) -> dict[str, list["CrossBankFact"]]:
        """Execute recall in parallel across specified banks."""
        # TODO: Implement parallel recall in Sprint 2
        raise NotImplementedError("CrossBankOrchestrator._parallel_recall() will be implemented in Sprint 2")

    async def _fuse_results(
        self,
        bank_results: dict[str, list["CrossBankFact"]],
        max_results: int,
    ) -> list["CrossBankFact"]:
        """Fuse and rank results from multiple banks using RRF."""
        # TODO: Implement reciprocal rank fusion in Sprint 2
        raise NotImplementedError("CrossBankOrchestrator._fuse_results() will be implemented in Sprint 2")

    async def _gather_evidence(
        self,
        query: str,
        banks: list["BankInfo"],
        budget_allocation: BudgetAllocation,
        include_mental_models: bool,
        request_context: "RequestContext",
    ) -> dict[str, Any]:
        """Gather evidence (facts + mental models) from multiple banks."""
        # TODO: Implement evidence gathering in Sprint 2
        raise NotImplementedError("CrossBankOrchestrator._gather_evidence() will be implemented in Sprint 2")