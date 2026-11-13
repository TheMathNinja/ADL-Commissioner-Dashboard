import copy
from pathlib import Path
import smtplib
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from email_delivery_state import deliver_once, DeliveryUncertain
from smtp_delivery import send_message_with_retries, PartialDeliveryError


class DeliveryTests(unittest.TestCase):
    def test_temporary_rejection_then_success(self):
        smtp, sleep = Mock(), Mock()
        smtp.send_message.side_effect = [smtplib.SMTPDataError(451, b'temporary'), {}]
        send_message_with_retries(smtp, Mock(), 'sender', ['recipient'], sleep)
        self.assertEqual(smtp.send_message.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_permanent_and_ambiguous_failures_are_not_retried(self):
        for error in (smtplib.SMTPDataError(550, b'permanent'), TimeoutError(),
                      smtplib.SMTPServerDisconnected()):
            smtp = Mock()
            smtp.send_message.side_effect = error
            with self.assertRaises(type(error)):
                send_message_with_retries(smtp, Mock(), 'sender', ['recipient'], Mock())
            self.assertEqual(smtp.send_message.call_count, 1)

    def test_retry_bound(self):
        smtp = Mock()
        smtp.send_message.side_effect = smtplib.SMTPDataError(451, b'temporary')
        with self.assertRaises(smtplib.SMTPDataError):
            send_message_with_retries(smtp, Mock(), 'sender', ['recipient'], Mock())
        self.assertEqual(smtp.send_message.call_count, 3)

    def test_partial_acceptance_is_not_success_or_retried(self):
        smtp = Mock()
        smtp.send_message.return_value = {'b': (450, b'refused')}
        with self.assertRaises(PartialDeliveryError) as caught:
            send_message_with_retries(smtp, Mock(), 'sender', ['a', 'b'], Mock())
        self.assertEqual(caught.exception.accepted, ('a',))
        self.assertEqual(smtp.send_message.call_count, 1)

    def test_receipt_precedes_smtp_and_rerun_does_not_send(self):
        state, snapshots = {}, []
        def send():
            self.assertEqual(snapshots[-1]['delivery_receipts']['issue']['status'], 'sending')
        save = lambda: snapshots.append(copy.deepcopy(state))
        self.assertTrue(deliver_once(state, 'issue', send, save))
        self.assertFalse(deliver_once(state, 'issue', Mock(side_effect=AssertionError()), save))
        self.assertEqual(len(snapshots), 2)

    def test_failed_initial_save_never_sends(self):
        send = Mock()
        with self.assertRaises(OSError):
            deliver_once({}, 'issue', send, Mock(side_effect=OSError()))
        send.assert_not_called()

    def test_crash_after_smtp_does_not_blindly_repeat(self):
        state, remote, calls = {}, {}, []
        def save():
            if remote:
                raise OSError('accepted receipt write failed')
            remote.update(copy.deepcopy(state))
        with self.assertRaises(OSError):
            deliver_once(state, 'issue', lambda: calls.append('smtp accepted'), save)
        with self.assertRaises(DeliveryUncertain):
            deliver_once(remote, 'issue', lambda: calls.append('duplicate'), lambda: None)
        self.assertEqual(calls, ['smtp accepted'])

    def test_explicit_rejection_can_retry_but_timeout_requires_review(self):
        for error, status in ((smtplib.SMTPDataError(451, b'rejected'), 'rejected'),
                              (TimeoutError(), 'uncertain')):
            state = {}
            with self.assertRaises(type(error)):
                deliver_once(state, 'issue', Mock(side_effect=error), lambda: None)
            self.assertEqual(state['delivery_receipts']['issue']['status'], status)
            if status == 'rejected':
                self.assertTrue(deliver_once(state, 'issue', lambda: None, lambda: None))
            else:
                with self.assertRaises(DeliveryUncertain):
                    deliver_once(state, 'issue', lambda: None, lambda: None)

    def test_distinct_issues_remain_deliverable(self):
        state, send = {}, Mock()
        deliver_once(state, 'one', send, lambda: None)
        deliver_once(state, 'two', send, lambda: None)
        self.assertEqual(send.call_count, 2)


if __name__ == '__main__':
    unittest.main()
