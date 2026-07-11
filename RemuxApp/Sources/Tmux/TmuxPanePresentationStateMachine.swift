/// Pure reducer for the asynchronous release/confirm/create pane handoff.
///
/// It intentionally owns no surface or controller. `TmuxTerminalSession`
/// performs the returned effect and feeds the completion back as an event.
/// This keeps native lifetime work serialized while making every legal state
/// and interruption explicit.
struct TmuxPanePresentationStateMachine: Equatable {
    struct Transition: Equatable {
        var target: TmuxPaneID
        var selectionIntent: TmuxPaneID?
    }

    enum Failure: Equatable {
        case release(TmuxPaneID?)
        case create(TmuxPaneID)
    }

    enum CompletionPolicy: Equatable {
        case continuePresentation
        case cancel
        case stop
    }

    enum State: Equatable {
        case idle
        case releasing(Transition, CompletionPolicy)
        case awaitingTopology(Transition)
        case creating(Transition, CompletionPolicy)
        case discarding(Transition, shouldRedrive: Bool, CompletionPolicy)
        case failed(confirmedPane: TmuxPaneID?, Failure)
        case stopped
    }

    enum Event: Equatable {
        case requirePresentation(target: TmuxPaneID, outgoing: TmuxPaneID?)
        case requestSelection(target: TmuxPaneID, outgoing: TmuxPaneID?)
        case releaseCompleted(succeeded: Bool, confirmedPane: TmuxPaneID?)
        case reconcile(confirmedPane: TmuxPaneID?)
        case selectionRequestFailed(confirmedPane: TmuxPaneID?)
        case createCompleted(
            pane: TmuxPaneID,
            succeeded: Bool,
            stillDesired: Bool,
            confirmedPane: TmuxPaneID?
        )
        case discardCompleted(succeeded: Bool, confirmedPane: TmuxPaneID?)
        case detached
        case stop
    }

    enum Effect: Equatable {
        case none
        case release(outgoing: TmuxPaneID?)
        case evaluateTopology
        case create(TmuxPaneID)
        case present(TmuxPaneID)
        case discard(shouldRedrive: Bool)
        case finished(shouldRedrive: Bool)
    }

    private(set) var state: State = .idle

    var hasNativeWorkInFlight: Bool {
        switch state {
        case .releasing, .creating, .discarding:
            true
        case .idle, .awaitingTopology, .failed, .stopped:
            false
        }
    }

    var targetPaneID: TmuxPaneID? {
        switch state {
        case .releasing(let transition, _),
             .awaitingTopology(let transition),
             .creating(let transition, _),
             .discarding(let transition, _, _):
            transition.target
        case .idle, .failed, .stopped:
            nil
        }
    }

    func isCreateStillDesired(
        pane: TmuxPaneID,
        confirmedPane: TmuxPaneID?
    ) -> Bool {
        guard case .creating(let transition, .continuePresentation) = state else {
            return false
        }
        return transition.target == pane
            && confirmedPane == pane
            && (transition.selectionIntent == nil || transition.selectionIntent == pane)
    }

    mutating func reduce(_ event: Event) -> Effect {
        switch event {
        case .requirePresentation(let target, let outgoing):
            return beginIfIdle(target: target, outgoing: outgoing, selectionIntent: nil)

        case .requestSelection(let target, let outgoing):
            return requestSelection(target: target, outgoing: outgoing)

        case .releaseCompleted(let succeeded, let confirmedPane):
            return releaseCompleted(succeeded: succeeded, confirmedPane: confirmedPane)

        case .reconcile(let confirmedPane):
            return reconcile(confirmedPane: confirmedPane)

        case .selectionRequestFailed(let confirmedPane):
            return selectionRequestFailed(confirmedPane: confirmedPane)

        case .createCompleted(
            let pane,
            let succeeded,
            let stillDesired,
            let confirmedPane
        ):
            return createCompleted(
                pane: pane,
                succeeded: succeeded,
                stillDesired: stillDesired,
                confirmedPane: confirmedPane
            )

        case .discardCompleted(let succeeded, let confirmedPane):
            return discardCompleted(
                succeeded: succeeded,
                confirmedPane: confirmedPane
            )

        case .detached:
            return detached()

        case .stop:
            return interrupt(with: .stop)
        }
    }

    private mutating func beginIfIdle(
        target: TmuxPaneID,
        outgoing: TmuxPaneID?,
        selectionIntent: TmuxPaneID?
    ) -> Effect {
        switch state {
        case .idle, .failed:
            state = .releasing(
                Transition(target: target, selectionIntent: selectionIntent),
                .continuePresentation
            )
            return .release(outgoing: outgoing)
        case .releasing, .awaitingTopology, .creating, .discarding, .stopped:
            return .none
        }
    }

    private mutating func requestSelection(
        target: TmuxPaneID,
        outgoing: TmuxPaneID?
    ) -> Effect {
        switch state {
        case .idle, .failed:
            return beginIfIdle(
                target: target,
                outgoing: outgoing,
                selectionIntent: target
            )

        case .releasing(var transition, let policy):
            guard policy == .continuePresentation else { return .none }
            transition.target = target
            transition.selectionIntent = target
            state = .releasing(transition, policy)
            return .none

        case .awaitingTopology(var transition):
            transition.target = target
            transition.selectionIntent = target
            state = .awaitingTopology(transition)
            return .evaluateTopology

        case .creating(var transition, let policy):
            guard policy == .continuePresentation else { return .none }
            transition.selectionIntent = target
            state = .creating(transition, policy)
            return .none

        case .discarding(var transition, let shouldRedrive, let policy):
            guard policy == .continuePresentation else { return .none }
            transition.selectionIntent = target
            state = .discarding(transition, shouldRedrive: shouldRedrive, policy)
            return .none

        case .stopped:
            return .none
        }
    }

    private mutating func releaseCompleted(
        succeeded: Bool,
        confirmedPane: TmuxPaneID?
    ) -> Effect {
        guard case .releasing(let transition, let policy) = state else {
            return .none
        }
        guard succeeded else {
            switch policy {
            case .stop:
                state = .stopped
            case .continuePresentation, .cancel:
                state = .failed(
                    confirmedPane: confirmedPane,
                    .release(confirmedPane)
                )
            }
            return .finished(shouldRedrive: false)
        }

        switch policy {
        case .continuePresentation:
            state = .awaitingTopology(transition)
            return .evaluateTopology
        case .cancel:
            state = .idle
            return .finished(shouldRedrive: false)
        case .stop:
            state = .stopped
            return .finished(shouldRedrive: false)
        }
    }

    private mutating func reconcile(confirmedPane: TmuxPaneID?) -> Effect {
        switch state {
        case .awaitingTopology(let transition):
            if let selectionIntent = transition.selectionIntent {
                guard confirmedPane == selectionIntent else { return .none }
                state = .creating(transition, .continuePresentation)
                return .create(selectionIntent)
            }

            guard confirmedPane == transition.target else {
                state = .idle
                return .finished(shouldRedrive: confirmedPane != nil)
            }
            state = .creating(transition, .continuePresentation)
            return .create(transition.target)

        case .failed:
            guard let confirmedPane else {
                state = .idle
                return .finished(shouldRedrive: false)
            }
            state = .releasing(
                Transition(target: confirmedPane, selectionIntent: nil),
                .continuePresentation
            )
            return .release(outgoing: nil)

        case .idle, .releasing, .creating, .discarding, .stopped:
            return .none
        }
    }

    private mutating func selectionRequestFailed(
        confirmedPane: TmuxPaneID?
    ) -> Effect {
        switch state {
        case .releasing(var transition, let policy):
            transition.selectionIntent = nil
            state = .releasing(transition, policy)
            return .none

        case .awaitingTopology(var transition):
            transition.selectionIntent = nil
            state = .awaitingTopology(transition)
            return reconcile(confirmedPane: confirmedPane)

        case .creating(var transition, let policy):
            transition.selectionIntent = nil
            state = .creating(transition, policy)
            return .none

        case .discarding(var transition, let shouldRedrive, let policy):
            transition.selectionIntent = nil
            state = .discarding(transition, shouldRedrive: shouldRedrive, policy)
            return .none

        case .idle, .failed, .stopped:
            return .none
        }
    }

    private mutating func createCompleted(
        pane: TmuxPaneID,
        succeeded: Bool,
        stillDesired: Bool,
        confirmedPane: TmuxPaneID?
    ) -> Effect {
        guard case .creating(let transition, let policy) = state,
              transition.target == pane
        else {
            guard succeeded else { return .none }
            if !hasNativeWorkInFlight {
                let completionPolicy: CompletionPolicy = state == .stopped
                    ? .stop
                    : .cancel
                state = .discarding(
                    Transition(target: pane, selectionIntent: nil),
                    shouldRedrive: false,
                    completionPolicy
                )
            }
            return .discard(shouldRedrive: false)
        }

        guard policy == .continuePresentation else {
            if succeeded {
                state = .discarding(
                    transition,
                    shouldRedrive: false,
                    policy
                )
                return .discard(shouldRedrive: false)
            }
            state = policy == .stop ? .stopped : .idle
            return .finished(shouldRedrive: false)
        }

        guard succeeded else {
            if stillDesired {
                state = .failed(
                    confirmedPane: confirmedPane,
                    .create(pane)
                )
                return .finished(shouldRedrive: false)
            }
            state = .idle
            return .finished(shouldRedrive: true)
        }

        guard stillDesired else {
            state = .discarding(
                transition,
                shouldRedrive: true,
                .continuePresentation
            )
            return .discard(shouldRedrive: true)
        }

        state = .idle
        return .present(pane)
    }

    private mutating func discardCompleted(
        succeeded: Bool,
        confirmedPane: TmuxPaneID?
    ) -> Effect {
        guard case .discarding(_, let shouldRedrive, let policy) = state else {
            return .none
        }
        guard succeeded else {
            if policy == .stop {
                state = .stopped
            } else {
                state = .failed(
                    confirmedPane: confirmedPane,
                    .release(confirmedPane)
                )
            }
            return .finished(shouldRedrive: false)
        }
        switch policy {
        case .continuePresentation:
            state = .idle
            return .finished(shouldRedrive: shouldRedrive)
        case .cancel:
            state = .idle
            return .finished(shouldRedrive: false)
        case .stop:
            state = .stopped
            return .finished(shouldRedrive: false)
        }
    }

    private mutating func interrupt(with policy: CompletionPolicy) -> Effect {
        precondition(policy != .continuePresentation)
        switch state {
        case .releasing(let transition, _):
            state = .releasing(transition, policy)
            return .none
        case .creating(let transition, _):
            state = .creating(transition, policy)
            return .none
        case .discarding(let transition, _, _):
            state = .discarding(
                transition,
                shouldRedrive: false,
                policy
            )
            return .none
        case .awaitingTopology, .failed, .idle:
            state = policy == .stop ? .stopped : .idle
            return .finished(shouldRedrive: false)
        case .stopped:
            return .none
        }
    }

    private mutating func detached() -> Effect {
        switch state {
        case .releasing(let transition, .continuePresentation):
            state = .releasing(transition, .cancel)
            return .none

        case .creating(var transition, .continuePresentation):
            transition.selectionIntent = nil
            state = .creating(transition, .continuePresentation)
            return .none

        case .discarding(
            var transition,
            let shouldRedrive,
            .continuePresentation
        ):
            transition.selectionIntent = nil
            state = .discarding(
                transition,
                shouldRedrive: shouldRedrive,
                .continuePresentation
            )
            return .none

        case .awaitingTopology, .failed:
            state = .idle
            return .finished(shouldRedrive: false)

        case .idle,
             .releasing(_, .cancel),
             .releasing(_, .stop),
             .creating(_, .cancel),
             .creating(_, .stop),
             .discarding(_, _, .cancel),
             .discarding(_, _, .stop),
             .stopped:
            return .none
        }
    }
}
