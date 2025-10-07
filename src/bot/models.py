from django.db import models
from django.utils import timezone


class TimestampModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class User(TimestampModel):
    hashed_user_id = models.CharField(max_length=255, unique=True)
    left_free_seconds = models.IntegerField(default=0)
    left_purchased_seconds = models.IntegerField(default=0)
    last_free_reset_at = models.DateTimeField(default=timezone.now)
    warned_at = models.DateTimeField(null=True, blank=True)


class Transcription(TimestampModel):
    user = models.ForeignKey(
        User, on_delete=models.CASCADE, related_name="transcriptions"
    )
    audio_duration = models.IntegerField()
    transcription_time = models.FloatField()


class Payment(TimestampModel):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="payments")
    payment_id = models.CharField(max_length=255)
    total_amount = models.IntegerField()
