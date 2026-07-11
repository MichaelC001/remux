import XCTest

@testable import Remux

final class TmuxPanePresentationStateMachineTests: XCTestCase {
    func testTransitionTable() {
        let cases: [(String, [TmuxPanePresentationStateMachine.Event], TmuxPanePresentationStateMachine.State, TmuxPanePresentationStateMachine.Effect)] = [
            (
                "topology starts release",
                [.requirePresentation(target: 10, outgoing: nil)],
                .releasing(.init(target: 10, selectionIntent: nil), .continuePresentation),
                .release(outgoing: nil)
            ),
            (
                "selection starts eager release",
                [.requestSelection(target: 11, outgoing: 10)],
                .releasing(.init(target: 11, selectionIntent: 11), .continuePresentation),
                .release(outgoing: 10)
            ),
            (
                "selection retargets release",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .requestSelection(target: 12, outgoing: nil),
                ],
                .releasing(.init(target: 12, selectionIntent: 12), .continuePresentation),
                .none
            ),
            (
                "release waits for topology",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                ],
                .awaitingTopology(.init(target: 11, selectionIntent: 11)),
                .evaluateTopology
            ),
            (
                "confirmation creates target",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 11),
                ],
                .creating(.init(target: 11, selectionIntent: 11), .continuePresentation),
                .create(11)
            ),
            (
                "intermediate confirmation stays waiting",
                [
                    .requestSelection(target: 12, outgoing: 10),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 11),
                ],
                .awaitingTopology(.init(target: 12, selectionIntent: 12)),
                .none
            ),
            (
                "selection failure recreates confirmed pane",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .selectionRequestFailed(confirmedPane: 10),
                ],
                .idle,
                .finished(shouldRedrive: true)
            ),
            (
                "create success presents",
                [
                    .requirePresentation(target: 10, outgoing: nil),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 10),
                    .createCompleted(
                        pane: 10,
                        succeeded: true,
                        stillDesired: true,
                        confirmedPane: 10
                    ),
                ],
                .idle,
                .present(10)
            ),
            (
                "create failure records confirmed failure",
                [
                    .requirePresentation(target: 10, outgoing: nil),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 10),
                    .createCompleted(
                        pane: 10,
                        succeeded: false,
                        stillDesired: true,
                        confirmedPane: 10
                    ),
                ],
                .failed(confirmedPane: 10, .create(10)),
                .finished(shouldRedrive: false)
            ),
            (
                "stale create is discarded",
                [
                    .requirePresentation(target: 10, outgoing: nil),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 10),
                    .requestSelection(target: 11, outgoing: nil),
                    .createCompleted(
                        pane: 10,
                        succeeded: true,
                        stillDesired: false,
                        confirmedPane: 11
                    ),
                ],
                .discarding(
                    .init(target: 10, selectionIntent: 11),
                    shouldRedrive: true,
                    .continuePresentation
                ),
                .discard(shouldRedrive: true)
            ),
            (
                "stop while releasing drains to stopped",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .stop,
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                ],
                .stopped,
                .finished(shouldRedrive: false)
            ),
            (
                "detach while releasing drains without creating",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .detached,
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                ],
                .idle,
                .finished(shouldRedrive: false)
            ),
            (
                "detach while creating preserves the confirmed surface",
                [
                    .requestSelection(target: 11, outgoing: 10),
                    .releaseCompleted(succeeded: true, confirmedPane: 10),
                    .reconcile(confirmedPane: 11),
                    .detached,
                    .createCompleted(
                        pane: 11,
                        succeeded: true,
                        stillDesired: true,
                        confirmedPane: 11
                    ),
                ],
                .idle,
                .present(11)
            ),
        ]

        for testCase in cases {
            var machine = TmuxPanePresentationStateMachine()
            var effect: TmuxPanePresentationStateMachine.Effect = .none
            for event in testCase.1 {
                effect = machine.reduce(event)
            }
            XCTAssertEqual(machine.state, testCase.2, testCase.0)
            XCTAssertEqual(effect, testCase.3, testCase.0)
        }
    }

    func testEveryEventIsSafeInEveryReachableState() {
        let states: [TmuxPanePresentationStateMachine.State] = [
            .idle,
            .releasing(.init(target: 10, selectionIntent: 10), .continuePresentation),
            .awaitingTopology(.init(target: 10, selectionIntent: 10)),
            .creating(.init(target: 10, selectionIntent: 10), .continuePresentation),
            .discarding(
                .init(target: 10, selectionIntent: 11),
                shouldRedrive: true,
                .continuePresentation
            ),
            .failed(confirmedPane: nil, .create(10)),
            .stopped,
        ]
        let events: [TmuxPanePresentationStateMachine.Event] = [
            .requirePresentation(target: 10, outgoing: 9),
            .requestSelection(target: 11, outgoing: 10),
            .releaseCompleted(succeeded: true, confirmedPane: 10),
            .releaseCompleted(succeeded: false, confirmedPane: nil),
            .reconcile(confirmedPane: 10),
            .selectionRequestFailed(confirmedPane: 10),
            .createCompleted(
                pane: 10,
                succeeded: true,
                stillDesired: true,
                confirmedPane: 10
            ),
            .createCompleted(
                pane: 10,
                succeeded: false,
                stillDesired: false,
                confirmedPane: nil
            ),
            .discardCompleted(succeeded: true, confirmedPane: 10),
            .discardCompleted(succeeded: false, confirmedPane: nil),
            .detached,
            .stop,
        ]

        for state in states {
            for event in events {
                var machine = machine(in: state)
                _ = machine.reduce(event)
            }
        }
    }

    private func machine(
        in targetState: TmuxPanePresentationStateMachine.State
    ) -> TmuxPanePresentationStateMachine {
        var machine = TmuxPanePresentationStateMachine()
        switch targetState {
        case .idle:
            break
        case .releasing:
            _ = machine.reduce(.requestSelection(target: 10, outgoing: 9))
        case .awaitingTopology:
            _ = machine.reduce(.requestSelection(target: 10, outgoing: 9))
            _ = machine.reduce(.releaseCompleted(succeeded: true, confirmedPane: 9))
        case .creating:
            _ = machine.reduce(.requestSelection(target: 10, outgoing: 9))
            _ = machine.reduce(.releaseCompleted(succeeded: true, confirmedPane: 9))
            _ = machine.reduce(.reconcile(confirmedPane: 10))
        case .discarding:
            _ = machine.reduce(.requirePresentation(target: 10, outgoing: nil))
            _ = machine.reduce(.releaseCompleted(succeeded: true, confirmedPane: 10))
            _ = machine.reduce(.reconcile(confirmedPane: 10))
            _ = machine.reduce(.requestSelection(target: 11, outgoing: nil))
            _ = machine.reduce(.createCompleted(
                pane: 10,
                succeeded: true,
                stillDesired: false,
                confirmedPane: 11
            ))
        case .failed:
            _ = machine.reduce(.requirePresentation(target: 10, outgoing: nil))
            _ = machine.reduce(.releaseCompleted(succeeded: true, confirmedPane: 10))
            _ = machine.reduce(.reconcile(confirmedPane: 10))
            _ = machine.reduce(.createCompleted(
                pane: 10,
                succeeded: false,
                stillDesired: true,
                confirmedPane: 10
            ))
        case .stopped:
            _ = machine.reduce(.stop)
        }
        return machine
    }
}
