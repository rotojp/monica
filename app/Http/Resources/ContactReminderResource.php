<?php

namespace App\Http\Resources;

use App\Helpers\DateHelper;
use App\Helpers\NameHelper;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\ContactReminder
 */
class ContactReminderResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     */
    public function toArray($request): array
    {
        return [
            'id' => $this->id,
            'label' => $this->label,
            'day' => $this->day,
            'month' => $this->month,
            'year' => $this->year,
            'type' => $this->type,
            'frequency_number' => $this->frequency_number,
            'last_triggered_at' => DateHelper::getTimestamp($this->last_triggered_at),
            'contact' => $this->contact ? [
                'id' => $this->contact->id,
                'name' => NameHelper::formatContactName($request->user(), $this->contact),
                'vault_id' => $this->contact->vault_id,
            ] : null,
            'created_at' => DateHelper::getTimestamp($this->created_at),
            'updated_at' => DateHelper::getTimestamp($this->updated_at),
        ];
    }
}
